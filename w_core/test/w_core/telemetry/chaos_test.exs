defmodule WCore.Telemetry.ChaosTest do
  @moduledoc """
  Teste de Caos: Prova a ausência de Race Condition no contador ETS sob
  10.000 escritas verdadeiramente concorrentes.

  ## Por que este teste é necessário?

  O padrão ingênuo de incrementar um contador em memória compartilhada
  é inerentemente inseguro sob concorrência:

      # ❌ PADRÃO INSEGURO (leitura → modificação → escrita):
      count = :ets.lookup_element(table, key, 5)   # processo A lê 42
      # processo B também lê 42 antes de A escrever
      :ets.update_element(table, key, {5, count + 1})  # A escreve 43
      # B escreve 43 — perdemos um incremento!

  O BEAM resolve isso com `:ets.update_counter/4`, que realiza a operação
  de incremento de forma ATÔMICA no nível do runtime — não há janela de
  tempo entre "ler" e "escrever". É equivalente a um `FETCH_ADD` atômico
  na arquitetura de hardware.

  ## Estrutura do Teste

  Spawna 10.000 processos BEAM concorrentes, cada um chamando
  `Cache.record_event/4` para o mesmo `machine_id`. Ao final, o contador
  no ETS deve ser EXATAMENTE 10.000 — qualquer valor menor prova perda
  de evento por race condition.
  """

  # async: false obrigatório — a tabela ETS é um recurso global nomeado.
  # Rodar em paralelo com outros testes que usam o mesmo atom causaria
  # conflito na criação da tabela (já existe) ou leituras cruzadas.
  use ExUnit.Case, async: false

  alias WCore.Telemetry.Cache

  @machine_id "CHAOS-01"
  @total_events 10_000

  # A application de test já sobe o Cache (e a tabela ETS) via Supervisor.
  # Não podemos re-iniciá-lo — `:already_started` seria retornado.
  # Em vez disso, removemos apenas as chaves usadas por ESTE teste antes
  # de cada execução, garantindo isolamento sem reiniciar o processo.
  setup do
    :ets.delete(Cache.table(), @machine_id)

    for id <- ["CHAOS-A", "CHAOS-B", "CHAOS-C", "CHAOS-D"] do
      :ets.delete(Cache.table(), id)
    end

    :ok
  end

  test "10.000 eventos concorrentes não perdem nenhuma contagem no ETS" do
    timestamp = NaiveDateTime.utc_now(:second)

    # Spawna 10.000 Tasks de uma só vez — cada uma é um processo BEAM leve.
    # Task.async/1 retorna imediatamente; o trabalho ocorre em paralelo.
    # Com 10.000 processos apontando para o mesmo ETS ao mesmo tempo,
    # este é o cenário máximo de contenção possível para o nosso cache.
    tasks =
      for _ <- 1..@total_events do
        Task.async(fn ->
          Cache.record_event(
            @machine_id,
            "ok",
            %{"temperature" => 72.5, "vibration" => 3.1},
            timestamp
          )
        end)
      end

    # Aguarda a conclusão de TODAS as 10.000 tasks antes de verificar.
    # Timeout de 30s — em hardware moderno este teste completa em < 2s.
    Task.await_many(tasks, 30_000)

    # ── Asserção Central ──────────────────────────────────────────────
    # Se :ets.update_counter/4 não fosse atômico, race conditions fariam
    # este número ser menor que 10.000 (eventos "pisariam" uns nos outros).
    {_id, _status, _payload, _ts, event_count} = Cache.lookup(@machine_id)

    assert event_count == @total_events,
           """
           RACE CONDITION DETECTADA!
           Esperado : #{@total_events} eventos
           Registrado: #{event_count} eventos
           Perdidos  : #{@total_events - event_count} incrementos foram sobrescritos.
           """
  end

  test "contadores de múltiplas máquinas são independentes e precisos" do
    # Prova que a atomicidade vale mesmo quando múltiplos machine_ids
    # concorrem pela tabela ETS ao mesmo tempo (cenário real da Planta 42).
    machine_ids = ["CHAOS-A", "CHAOS-B", "CHAOS-C", "CHAOS-D"]
    events_per_machine = 2_500  # 4 × 2.500 = 10.000 eventos no total
    timestamp = NaiveDateTime.utc_now(:second)

    tasks =
      for machine_id <- machine_ids,
          _ <- 1..events_per_machine do
        Task.async(fn ->
          Cache.record_event(machine_id, "ok", %{"temperature" => 55.0}, timestamp)
        end)
      end

    Task.await_many(tasks, 30_000)

    # Cada máquina deve ter exatamente 2.500 eventos — sem "vazamento" entre chaves
    for machine_id <- machine_ids do
      {_id, _status, _payload, _ts, count} = Cache.lookup(machine_id)

      assert count == events_per_machine,
             "#{machine_id}: esperado #{events_per_machine}, got #{count}"
    end
  end
end
