defmodule WCore.Telemetry.Cache do
  @moduledoc """
  Processo "dono" (owner) da tabela ETS de telemetria.

  ## Por que um GenServer se não recebe mensagens de eventos?

  No BEAM, uma tabela ETS pertence ao processo que a criou. Se esse processo
  morrer, a tabela é destruída. Ao usar um GenServer supervisionado como dono,
  garantimos que a tabela sobrevive a falhas e reinicializações controladas.

  A função `record_event/4` escreve *diretamente* no ETS, sem passar pela
  caixa de entrada (mailbox) do GenServer. Isso é intencional e é a principal
  decisão de performance deste módulo.

  ## Trade-off: `update_counter` + `update_element` (duas operações)

  Para manter o contador de eventos (`event_count`) preciso e atômico,
  usamos `:ets.update_counter/4` com um valor padrão. Depois, atualizamos
  os demais campos (status, payload, timestamp) via `:ets.update_element/3`.

  Isso significa que, sob altíssima concorrência, é possível que o campo
  `status` de uma thread A sobrescreva o de B após o counter já ter sido
  incrementado por B. O counter será sempre correto; o estado refletirá
  o *último escritor* — aceitável para telemetria onde o dado mais recente
  é o mais relevante.
  """

  use GenServer

  @table :w_core_telemetry_cache

  # Posições na tupla ETS: {machine_id, status, payload, timestamp, event_count}
  @pos_status 2
  @pos_payload 3
  @pos_timestamp 4
  @pos_counter 5

  # ---------------------------------------------------------------------------
  # API Pública
  # ---------------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Retorna o nome atômico da tabela ETS para uso externo (ex: FlushWorker).
  """
  def table, do: @table

  @doc """
  Grava um evento de telemetria diretamente na tabela ETS.

  ## Por que não usar `GenServer.cast/2`?

  Com `cast`, cada chamada enviaria uma mensagem para a mailbox do GenServer.
  Sob 1.000 eventos/segundo, a mailbox ficaria saturada — é exatamente o
  gargalo que este padrão foi criado para evitar.

  A escrita direta no ETS é thread-safe por design: o BEAM usa RW-locks
  internamente por bucket de hash, garantindo isolamento sem serialização
  via processo único.
  """
  @spec record_event(String.t(), String.t(), map(), NaiveDateTime.t()) :: true
  def record_event(machine_id, status, payload, timestamp) do
    # Incrementa o contador atomicamente. Se a chave não existir, o 4º argumento
    # é inserido como default (com event_count=0) antes do incremento.
    # Resultado: primeira chamada → event_count=1; demais → incremento contínuo.
    :ets.update_counter(
      @table,
      machine_id,
      {@pos_counter, 1},
      {machine_id, status, payload, timestamp, 0}
    )

    # Atualiza os campos de estado para refletir o evento mais recente.
    # Operação separada do counter pois `:update_counter` só opera em integers.
    :ets.update_element(@table, machine_id, [
      {@pos_status, status},
      {@pos_payload, payload},
      {@pos_timestamp, timestamp}
    ])
  end

  @doc """
  Lê o estado atual de um sensor diretamente do ETS. O(1).
  Usado pelo LiveView para leituras quentes sem tocar no banco.
  """
  @spec lookup(String.t()) :: tuple() | nil
  def lookup(machine_id) do
    case :ets.lookup(@table, machine_id) do
      [record] -> record
      [] -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Callbacks do GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # O processo que chama :ets.new/2 se torna o "owner" da tabela.
    # Se este GenServer for reiniciado pelo Supervisor, a tabela é recriada.
    :ets.new(@table, [
      # :set → hash table, chave única (machine_id). O(1) para leitura e escrita.
      # (Alternativa :ordered_set seria O(log n) — só vale se precisarmos de
      # iteração ordenada por chave, o que não é o caso aqui.)
      :set,

      # :public → qualquer processo pode ler e escrever sem passar pelo owner.
      # Necessário para que FlushWorker e LiveView acessem sem mensagens.
      :public,

      # :named_table → acessível pelo átomo @table em qualquer lugar da app.
      :named_table,

      # read_concurrency: true → o BEAM usa uma RW-Lock por bucket de hash
      # em vez de um lock global. Sob muitos leitores simultâneos (ex: 50
      # conexões LiveView no dashboard), a contenção cai drasticamente.
      read_concurrency: true
    ])

    {:ok, %{}}
  end
end
