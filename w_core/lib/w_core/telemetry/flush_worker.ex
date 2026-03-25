defmodule WCore.Telemetry.FlushWorker do
  @moduledoc """
  Worker responsável por sincronizar o estado quente do ETS com o SQLite.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias WCore.Repo
  alias WCore.Telemetry.{Cache, Node, NodeMetric}

  @flush_interval 5_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    node_id_map = load_node_id_map()
    Logger.info("FlushWorker iniciado. #{map_size(node_id_map)} node(s) no mapa.")
    schedule_flush()
    {:ok, %{node_id_map: node_id_map}}
  end

  @impl true
  def handle_info(:flush, state) do
    new_state = do_flush(state)
    schedule_flush()
    {:noreply, new_state}
  end

  defp do_flush(%{node_id_map: node_id_map} = state) do
    records = :ets.tab2list(Cache.table())

    if records == [] do
      state
    else
      updated_map = maybe_refresh_node_map(node_id_map, records)
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      metrics =
        Enum.flat_map(records, fn {machine_id, status, payload, last_seen_at, event_count} ->
          case Map.get(updated_map, machine_id) do
            nil ->
              []
            node_id ->
              [%{
                node_id: node_id,
                status: status,
                last_payload: payload,
                last_seen_at: last_seen_at,
                total_events_processed: event_count,
                inserted_at: now,
                updated_at: now
              }]
          end
        end)

      if metrics != [] do
        # CORREÇÃO 1: Query estruturada para o UPSERT somar corretamente
        upsert_query = from m in NodeMetric,
          update: [
            set: [
              status: fragment("excluded.status"),
              last_payload: fragment("excluded.last_payload"),
              last_seen_at: fragment("excluded.last_seen_at"),
              updated_at: fragment("excluded.updated_at"),
              total_events_processed: m.total_events_processed + fragment("excluded.total_events_processed")
            ]
          ]

        {count, _} =
          Repo.insert_all(
            NodeMetric,
            metrics,
            on_conflict: upsert_query,
            conflict_target: :node_id
          )

        Logger.info("FlushWorker: #{count} registro(s) sincronizados.")

        # CORREÇÃO 2: Prevenção de Race Condition usando update_counter com valor negativo
        Enum.each(records, fn {machine_id, _, _, _, event_count} ->
          :ets.update_counter(Cache.table(), machine_id, {5, -event_count})
        end)
      end

      %{state | node_id_map: updated_map}
    end
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval)
  end

  defp load_node_id_map do
    Repo.all(from n in Node, select: {n.machine_identifier, n.id})
    |> Map.new()
  end

  defp maybe_refresh_node_map(current_map, records) do
    has_unknown = Enum.any?(records, fn {machine_id, _, _, _, _} -> not Map.has_key?(current_map, machine_id) end)
    if has_unknown, do: load_node_id_map(), else: current_map
  end
end
