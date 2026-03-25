defmodule WCore.Telemetry.FlushWorker do
  @moduledoc """
  Worker responsável por sincronizar o estado quente do ETS com o SQLite.

  ## Padrão Write-Behind

  Os eventos chegam em alta frequência e são absorvidos pelo ETS (memória).
  Este worker acorda a cada `@flush_interval` milissegundos, varre a tabela
  inteira e faz um único `INSERT ... ON CONFLICT DO UPDATE` (UPSERT) em lote.

  Resultado: N.000 eventos → 1 operação de I/O de disco a cada ciclo.

  ## Mapeamento machine_identifier → node_id

  A tabela ETS é indexada por `machine_identifier` (string), mas a tabela
  `node_metrics` exige `node_id` (integer, FK). O worker mantém este mapa
  em seu estado (`state.node_id_map`) e o recarrega do banco apenas quando
  detecta um `machine_id` desconhecido — evitando queries desnecessárias a
  cada ciclo de flush.

  ## Trade-off: `total_events_processed`

  O campo é incrementado via expressão SQL (`node_metrics.total_events_processed
  + excluded.total_events_processed`) e não por substituição direta. Isso
  garante que o total seja cumulativo mesmo com múltiplos ciclos de flush,
  sem precisar de um SELECT antes do INSERT.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias WCore.Repo
  alias WCore.Telemetry.{Cache, Node, NodeMetric}

  # Intervalo entre flushes. Configurável via config/runtime.exs se necessário.
  @flush_interval 5_000

  # ---------------------------------------------------------------------------
  # API Pública
  # ---------------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  # ---------------------------------------------------------------------------
  # Callbacks do GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # Carrega o mapa completo machine_identifier → node_id uma única vez.
    # Os nodes são registros estáticos (raramente adicionados em runtime).
    node_id_map = load_node_id_map()

    Logger.info("FlushWorker iniciado. #{map_size(node_id_map)} node(s) no mapa.")

    # Agenda o primeiro ciclo de flush.
    schedule_flush()

    {:ok, %{node_id_map: node_id_map}}
  end

  @impl true
  def handle_info(:flush, state) do
    new_state = do_flush(state)
    schedule_flush()
    {:noreply, new_state}
  end

  # ---------------------------------------------------------------------------
  # Lógica de Flush (privada)
  # ---------------------------------------------------------------------------

  defp do_flush(%{node_id_map: node_id_map} = state) do
    records = :ets.tab2list(Cache.table())

    if records == [] do
      # Nada no cache — ciclo vazio, sem I/O.
      state
    else
      # Verifica se há machine_ids desconhecidos. Se sim, recarrega o mapa
      # para capturar nodes cadastrados após a inicialização do worker.
      updated_map = maybe_refresh_node_map(node_id_map, records)

      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      # Converte registros do ETS em maps prontos para Repo.insert_all.
      # flat_map/1 descarta registros cujo node_id não existe no banco (log de aviso).
      metrics =
        Enum.flat_map(records, fn {machine_id, status, payload, last_seen_at, event_count} ->
          case Map.get(updated_map, machine_id) do
            nil ->
              Logger.warning("FlushWorker: machine_id desconhecido '#{machine_id}'. Ignorado.")
              []

            node_id ->
              [%{
                node_id: node_id,
                status: status,
                last_payload: payload,
                last_seen_at: last_seen_at,
                # event_count do ETS representa o delta acumulado desde o último flush.
                # O UPSERT abaixo soma este valor ao total já persistido no SQLite.
                total_events_processed: event_count,
                inserted_at: now,
                updated_at: now
              }]
          end
        end)

      if metrics != [] do
        {count, _} =
          Repo.insert_all(
            NodeMetric,
            metrics,
            # `on_conflict` define o que fazer quando node_id já existe na tabela.
            # Em vez de substituir `total_events_processed` pelo valor novo,
            # usamos uma expressão SQL para SOMAR: valor atual + delta do ETS.
            # Isso garante um contador cumulativo sem precisar de SELECT + UPDATE.
            on_conflict: [
              set: [
                status: fragment("excluded.status"),
                last_payload: fragment("excluded.last_payload"),
                last_seen_at: fragment("excluded.last_seen_at"),
                updated_at: fragment("excluded.updated_at"),
                total_events_processed:
                  fragment(
                    "node_metrics.total_events_processed + excluded.total_events_processed"
                  )
              ]
            ],
            conflict_target: :node_id
          )

        Logger.info("FlushWorker: #{count} registro(s) sincronizados ao SQLite.")

        # Após flush bem-sucedido, zera o contador de eventos no ETS para
        # evitar dupla contagem no próximo ciclo.
        Enum.each(records, fn {machine_id, _, _, _, _} ->
          :ets.update_element(Cache.table(), machine_id, [{5, 0}])
        end)
      end

      %{state | node_id_map: updated_map}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers (privados)
  # ---------------------------------------------------------------------------

  # Schedula o próximo flush usando send_after.
  # Por que não usar :timer.send_interval/2?
  # send_interval dispara em intervalos fixos, ignorando o tempo que o flush levou.
  # send_after garante que o próximo ciclo começa APÓS o atual terminar,
  # evitando que flushes lentos se sobreponham (back-pressure natural).
  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval)
  end

  # Carrega o mapa completo de machine_identifier → node_id do banco.
  # Uma única query SELECT retorna todos os pares necessários.
  defp load_node_id_map do
    Repo.all(from n in Node, select: {n.machine_identifier, n.id})
    |> Map.new()
  end

  # Recarrega o mapa somente se houver machine_ids ausentes.
  # Evita 1 query SELECT por ciclo de flush quando o mapa está completo.
  defp maybe_refresh_node_map(current_map, records) do
    has_unknown =
      Enum.any?(records, fn {machine_id, _, _, _, _} ->
        not Map.has_key?(current_map, machine_id)
      end)

    if has_unknown, do: load_node_id_map(), else: current_map
  end
end
