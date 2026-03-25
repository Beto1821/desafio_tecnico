# Script de população do banco de dados para ambiente de desenvolvimento.
#
# Execução:
#   mix run priv/repo/seeds.exs
#
# Idempotência: O script usa o padrão "get_or_insert" — para cada sensor,
# primeiro verifica se já existe pelo `machine_identifier` (unique index).
# Se existir, reutiliza o registro. Se não existir, insere.
# Rodar duas vezes produz o mesmo estado final, sem erros ou duplicatas.

alias WCore.Repo
alias WCore.Telemetry.Node
alias WCore.Telemetry.NodeMetric

now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

# ---------------------------------------------------------------------------
# Dados dos sensores da Planta 42
# Cada entrada: {machine_identifier, location, status, last_payload}
# ---------------------------------------------------------------------------
sensor_definitions = [
  {
    "TURBINE-01",
    "Setor A / Linha de Geração Principal",
    "ok",
    %{
      "temperature_c" => 485.2,
      "vibration_mm_s" => 1.8,
      "rpm" => 3600,
      "oil_pressure_bar" => 4.2,
      "inlet_temp_c" => 22.0
    }
  },
  {
    "TURBINE-02",
    "Setor A / Linha de Geração Reserva",
    "warning",
    %{
      "temperature_c" => 601.7,
      "vibration_mm_s" => 3.1,
      "rpm" => 3580,
      "oil_pressure_bar" => 3.9,
      "inlet_temp_c" => 24.5
    }
  },
  {
    "PUMP-A-01",
    "Setor B / Circuito de Resfriamento Primário",
    "ok",
    %{
      "flow_rate_l_min" => 320.0,
      "pressure_bar" => 6.8,
      "motor_temp_c" => 65.3,
      "vibration_mm_s" => 0.9,
      "cavitation_index" => 0.02
    }
  },
  {
    "PUMP-B-02",
    "Setor B / Circuito de Lubrificação",
    "critical",
    %{
      "flow_rate_l_min" => 89.5,
      "pressure_bar" => 2.1,
      "motor_temp_c" => 102.8,
      "vibration_mm_s" => 8.7,
      "cavitation_index" => 0.41
    }
  },
  {
    "COMPRESSOR-01",
    "Setor C / Estação de Ar Comprimido",
    "ok",
    %{
      "discharge_pressure_bar" => 8.5,
      "suction_pressure_bar" => 1.0,
      "discharge_temp_c" => 88.0,
      "motor_current_a" => 42.3,
      "rpm" => 1480
    }
  },
  {
    "CONVEYOR-LINE-3",
    "Setor D / Linha de Montagem 3",
    "warning",
    %{
      "belt_speed_m_s" => 0.8,
      "motor_temp_c" => 71.0,
      "load_kg" => 950.0,
      "tension_n" => 1850.0,
      "rpm" => 220
    }
  },
  {
    "BOILER-01",
    "Setor E / Casa de Vapor",
    "ok",
    %{
      "steam_pressure_bar" => 12.4,
      "water_level_pct" => 68.0,
      "flue_gas_temp_c" => 195.0,
      "fuel_flow_kg_h" => 142.0,
      "efficiency_pct" => 87.3
    }
  },
  {
    "EXHAUST-FAN-04",
    "Setor E / Exaustão da Casa de Vapor",
    "critical",
    %{
      "temperature_c" => 312.9,
      "static_pressure_pa" => 1450.0,
      "vibration_mm_s" => 12.3,
      "motor_current_a" => 78.5,
      "rpm" => 1420
    }
  }
]

# ---------------------------------------------------------------------------
# Inserção idempotente: get_or_insert para Node + NodeMetric
# ---------------------------------------------------------------------------
IO.puts("\n==> Iniciando seed dos sensores da Planta 42...\n")

Enum.each(sensor_definitions, fn {machine_id, location, status, payload} ->
  # Passo 1: Busca o node pelo identificador único. Se não existir, insere.
  node =
    case Repo.get_by(Node, machine_identifier: machine_id) do
      nil ->
        %Node{}
        |> Node.changeset(%{machine_identifier: machine_id, location: location})
        |> Repo.insert!()

      existing ->
        existing
    end

  # Passo 2: Busca a métrica vinculada ao node. Se não existir, insere.
  # Evitamos atualizar caso já exista para não sobrescrever dados de simulação em progresso.
  case Repo.get_by(NodeMetric, node_id: node.id) do
    nil ->
      %NodeMetric{}
      |> NodeMetric.changeset(%{
        node_id: node.id,
        status: status,
        total_events_processed: 0,
        last_payload: payload,
        last_seen_at: now
      })
      |> Repo.insert!()

      IO.puts("  [INSERIDO] #{machine_id} (#{location}) → status: #{status}")

    _existing ->
      IO.puts("  [IGNORADO] #{machine_id} já existe no banco. Pulando.")
  end
end)

IO.puts("\n==> Seed concluído. #{length(sensor_definitions)} sensores processados.\n")
