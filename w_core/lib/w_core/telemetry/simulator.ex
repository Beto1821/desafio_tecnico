defmodule WCore.Telemetry.Simulator do
  @moduledoc """
  Simulador de telemetria industrial — Fase 3.

  ## Responsabilidade
  Emular máquinas industriais enviando leituras de sensores em alta frequência
  para o Cache ETS. **Nunca toca no banco de dados diretamente.**

  ## Estratégia de Concorrência (por que `spawn` e não `send_after`?)

  Cada machine_identifier recebe seu próprio processo leve da BEAM via `spawn/1`.
  Cada processo executa um loop recursivo com `Process.sleep/1`.

  A alternativa (`Process.send_after` para o próprio GenServer) canalizaria
  *todos* os eventos pela mailbox deste GenServer — sob 8 sensores a 500ms cada,
  a mailbox não ficaria saturada, mas criaria um ponto único de serialização
  desnecessário. Com processos independentes:

  - Cada sensor é escalonado pelo BEAM de forma independente.
  - `Cache.record_event/4` escreve direto no ETS (lock por bucket, não global).
  - Uma falha em um sensor não afeta os demais nem este GenServer.

  ## Payload Gerado
  - `temperature`: 40.0–105.0 °C (float, 2 casas decimais)
  - `vibration`: 0.5–12.0 mm/s (float, 2 casas decimais)

  ## Cálculo de Status
  - `"critical"` se temperatura ≥ 100.0
  - `"warning"`  se temperatura ≥ 90.0
  - `"ok"`       caso contrário
  """

  use GenServer
  require Logger

  import Ecto.Query, only: [from: 2]

  alias WCore.Repo
  alias WCore.Telemetry.{Cache, Node}

  # Frequência de emissão por sensor (milissegundos)
  @interval_min 500
  @interval_max 2000

  # Faixas de leitura dos sensores
  @temp_min 40.0
  @temp_max 105.0
  @vibration_min 0.5
  @vibration_max 12.0

  # Limiares de alerta de temperatura (°C)
  @temp_warn 90.0
  @temp_crit 100.0

  # ---------------------------------------------------------------------------
  # API Pública
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------
  # Callbacks do GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    machine_ids = fetch_machine_ids()

    Logger.info(
      "[Simulator] Iniciando simulação para #{length(machine_ids)} máquinas: " <>
        inspect(machine_ids)
    )

    # Spawna um processo leve por sensor. O GenServer guarda os PIDs para
    # eventuais inspeções futuras (ex: /telemetry no dashboard de debug).
    sensor_pids =
      machine_ids
      |> Enum.map(fn machine_id ->
        pid = spawn(fn -> sensor_loop(machine_id) end)
        Logger.debug("[Simulator] Sensor iniciado — machine=#{machine_id} pid=#{inspect(pid)}")
        {machine_id, pid}
      end)
      |> Map.new()

    {:ok, %{sensor_pids: sensor_pids}}
  end

  # ---------------------------------------------------------------------------
  # Loop do Sensor (processo independente)
  # ---------------------------------------------------------------------------

  # Cada chamada a esta função representa um ciclo de leitura de um sensor.
  # O processo dorme por um intervalo aleatório antes do próximo ciclo,
  # simulando o jitter natural de hardware industrial.
  defp sensor_loop(machine_id) do
    {temperature, vibration} = generate_readings()
    status = calculate_status(temperature)

    payload = %{
      "temperature" => temperature,
      "vibration" => vibration
    }

    # Escreve direto no ETS — sem passar pelo GenServer do Cache.
    # Ver Cache.record_event/4 para a justificativa de performance.
    Cache.record_event(machine_id, status, payload, NaiveDateTime.utc_now(:second))

    # Intervalo aleatório para emular jitter real de sensores industriais.
    # :rand.uniform(N) → inteiro em 1..N, logo o resultado fica em
    # (@interval_min + 1)..@interval_max — dentro da faixa aceitável.
    interval = @interval_min + :rand.uniform(@interval_max - @interval_min)
    Process.sleep(interval)

    sensor_loop(machine_id)
  end

  # ---------------------------------------------------------------------------
  # Funções Auxiliares
  # ---------------------------------------------------------------------------

  # Busca apenas os identificadores das máquinas — sem carregar associações.
  # Chamado uma única vez no init; mudanças no banco exigem restart do Simulator.
  defp fetch_machine_ids do
    Repo.all(from n in Node, select: n.machine_identifier)
  end

  # Gera leituras aleatórias dentro das faixas operacionais esperadas.
  # :rand.uniform() → float em (0.0, 1.0], garantindo cobertura da faixa inteira.
  defp generate_readings do
    temperature =
      (@temp_min + :rand.uniform() * (@temp_max - @temp_min))
      |> Float.round(2)

    vibration =
      (@vibration_min + :rand.uniform() * (@vibration_max - @vibration_min))
      |> Float.round(2)

    {temperature, vibration}
  end

  defp calculate_status(temp) when temp >= @temp_crit, do: "critical"
  defp calculate_status(temp) when temp >= @temp_warn, do: "warning"
  defp calculate_status(_temp), do: "ok"
end
