defmodule WCoreWeb.TelemetryLive.Index do
  @moduledoc """
  Dashboard em tempo real da Planta 42.

  ## Estratégia de atualização: Polling via :timer vs PubSub por evento

  O Simulator gera ~16 eventos/segundo por sensor (8 sensores = ~128 eventos/s).
  Fazer PubSub.broadcast em cada evento inundaria todos os clientes conectados.
  Em vez disso, usamos `:timer.send_interval/3` para um "pull" do ETS a cada 1s:

  - O LiveView lê do ETS (O(1) por sensor, sem banco de dados).
  - O diff do assigns é calculado pelo LiveView engine — só o HTML alterado
    é enviado via WebSocket ao cliente.
  - 10 clientes conectados = 10 leituras/s do ETS, não 1.280 broadcasts/s.

  ## Leitura do banco de dados

  Os machine_identifiers são carregados do banco UMA ÚNICA VEZ no `mount/3`
  e armazenados em `socket.assigns.machine_ids`. Cada tick subsequente lê
  exclusivamente do ETS via `Cache.lookup/1`.
  """

  use WCoreWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias WCore.Repo
  alias WCore.Telemetry.{Cache, Node}

  @refresh_interval 1_000

  # ---------------------------------------------------------------------------
  # Mount
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    # Única query ao banco neste LiveView. Após isto, apenas ETS.
    machine_ids =
      Repo.all(from n in Node, select: n.machine_identifier)
      |> Enum.sort()

    # O timer só é iniciado na conexão WebSocket real (connected? = true).
    # Na renderização HTTP inicial, connected? = false — evitamos criar um
    # timer órfão que nunca seria cancelado.
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :tick)
    end

    {:ok,
     socket
     |> assign(:page_title, "Planta 42 — Telemetria")
     |> assign(:machine_ids, machine_ids)
     |> assign(:sensors, fetch_sensors(machine_ids))
     |> assign(:last_updated, Time.utc_now()),
     # Desativa o layout :app (que tem max-w-2xl) para o dashboard ocupar
     # toda a largura da tela. O root.html.heex ainda é usado para head/body.
     layout: false}
  end

  # ---------------------------------------------------------------------------
  # Handle Info
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:tick, socket) do
    {:noreply,
     socket
     |> assign(:sensors, fetch_sensors(socket.assigns.machine_ids))
     |> assign(:last_updated, Time.utc_now())}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100" style="font-family: 'JetBrains Mono', 'Courier New', monospace;">

      <%!-- ── HEADER ─────────────────────────────────────────────────── --%>
      <header class="bg-gray-900 border-b border-gray-800 px-6 py-4 sticky top-0 z-10">
        <div class="max-w-7xl mx-auto flex flex-wrap items-center justify-between gap-4">

          <div class="flex items-center gap-3">
            <span class="relative flex h-3 w-3">
              <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-green-400 opacity-75"></span>
              <span class="relative inline-flex rounded-full h-3 w-3 bg-green-500"></span>
            </span>
            <h1 class="text-lg font-bold tracking-widest text-white uppercase">
              Planta 42 <span class="text-gray-500">|</span> Telemetria Industrial
            </h1>
          </div>

          <div class="flex items-center gap-6 text-xs">
            <div class="flex items-center gap-1 text-green-400">
              <span class="w-2 h-2 rounded-full bg-green-500 inline-block"></span>
              <span class="font-bold">{ok_count(@sensors)}</span>
              <span class="text-gray-500 uppercase tracking-wider">Normal</span>
            </div>
            <div class="flex items-center gap-1 text-yellow-400">
              <span class="w-2 h-2 rounded-full bg-yellow-400 inline-block"></span>
              <span class="font-bold">{warning_count(@sensors)}</span>
              <span class="text-gray-500 uppercase tracking-wider">Alerta</span>
            </div>
            <div class="flex items-center gap-1 text-red-400">
              <span class="w-2 h-2 rounded-full bg-red-500 inline-block"></span>
              <span class="font-bold">{critical_count(@sensors)}</span>
              <span class="text-gray-500 uppercase tracking-wider">Crítico</span>
            </div>
            <div class="text-gray-600 border-l border-gray-700 pl-4">
              atualizado <span class="text-gray-400">{format_time(@last_updated)}</span>
            </div>
          </div>

        </div>
      </header>

      <%!-- ── GRID DE SENSORES ──────────────────────────────────────── --%>
      <main class="max-w-7xl mx-auto px-4 sm:px-6 py-8">
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-5">

          <div
            :for={sensor <- @sensors}
            class={["rounded-lg p-5 transition-colors duration-700", card_classes(sensor.status)]}
          >
            <%!-- Card Header --%>
            <div class="flex items-start justify-between mb-5">
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-2 mb-1">
                  <span class={["w-2 h-2 rounded-full flex-shrink-0", status_dot(sensor.status)]}></span>
                  <span class={["text-xs font-bold tracking-widest uppercase", status_text(sensor.status)]}>
                    {status_label(sensor.status)}
                  </span>
                </div>
                <h2 class="text-sm font-bold text-white tracking-wider truncate">
                  {sensor.machine_id}
                </h2>
              </div>
              <div class="text-right ml-3 flex-shrink-0">
                <div class="text-xs text-gray-600 uppercase tracking-wider">Eventos</div>
                <div class="text-xl font-bold text-white tabular-nums">{sensor.event_count}</div>
              </div>
            </div>

            <%!-- Leituras --%>
            <div class="space-y-2">

              <div class="flex justify-between items-center bg-black/30 rounded px-3 py-2.5">
                <div class="flex items-center gap-2">
                  <span class="text-gray-600 text-xs">▲</span>
                  <span class="text-xs text-gray-400 uppercase tracking-wider">Temp.</span>
                </div>
                <span class={["text-base font-bold tabular-nums", temp_color(sensor.temperature)]}>
                  {format_temp(sensor.temperature)}
                </span>
              </div>

              <div class="flex justify-between items-center bg-black/30 rounded px-3 py-2.5">
                <div class="flex items-center gap-2">
                  <span class="text-gray-600 text-xs">~</span>
                  <span class="text-xs text-gray-400 uppercase tracking-wider">Vibração</span>
                </div>
                <span class="text-base font-bold tabular-nums text-blue-400">
                  {format_vibration(sensor.vibration)}
                </span>
              </div>

            </div>

            <%!-- Card Footer --%>
            <div class="mt-4 pt-3 border-t border-white/5">
              <span class="text-xs text-gray-700">
                {format_last_seen(sensor.last_seen_at)}
              </span>
            </div>

          </div>

        </div>
      </main>

    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Lógica de dados (apenas ETS)
  # ---------------------------------------------------------------------------

  defp fetch_sensors(machine_ids) do
    Enum.map(machine_ids, fn machine_id ->
      case Cache.lookup(machine_id) do
        {_id, status, payload, last_seen_at, event_count} ->
          %{
            machine_id: machine_id,
            status: status,
            temperature: payload["temperature"],
            vibration: payload["vibration"],
            event_count: event_count,
            last_seen_at: last_seen_at
          }

        nil ->
          %{
            machine_id: machine_id,
            status: "offline",
            temperature: nil,
            vibration: nil,
            event_count: 0,
            last_seen_at: nil
          }
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers de contagem (para o header)
  # ---------------------------------------------------------------------------

  defp ok_count(sensors), do: Enum.count(sensors, &(&1.status == "ok"))
  defp warning_count(sensors), do: Enum.count(sensors, &(&1.status == "warning"))
  defp critical_count(sensors), do: Enum.count(sensors, &(&1.status == "critical"))

  # ---------------------------------------------------------------------------
  # Helpers de formatação
  # ---------------------------------------------------------------------------

  defp format_time(time), do: Time.to_string(time) |> String.slice(0, 8)

  defp format_temp(nil), do: "—"
  defp format_temp(t), do: "#{t} °C"

  defp format_vibration(nil), do: "—"
  defp format_vibration(v), do: "#{v} mm/s"

  defp format_last_seen(nil), do: "aguardando dados..."
  defp format_last_seen(dt), do: "último: #{NaiveDateTime.to_string(dt)}"

  # ---------------------------------------------------------------------------
  # Helpers de estilo por status
  # ---------------------------------------------------------------------------

  # animate-pulse no card inteiro quando crítico — o operador vê o card piscar
  defp card_classes("critical"), do: "border-2 border-red-500/80 bg-red-950/50 animate-pulse"
  defp card_classes("warning"), do: "border-2 border-yellow-400/70 bg-yellow-950/30"
  defp card_classes("ok"), do: "border-2 border-green-500/50 bg-green-950/20"
  defp card_classes(_), do: "border-2 border-gray-700/50 bg-gray-900/40"

  defp status_dot("critical"), do: "bg-red-500"
  defp status_dot("warning"), do: "bg-yellow-400"
  defp status_dot("ok"), do: "bg-green-500"
  defp status_dot(_), do: "bg-gray-600"

  defp status_text("critical"), do: "text-red-400"
  defp status_text("warning"), do: "text-yellow-400"
  defp status_text("ok"), do: "text-green-400"
  defp status_text(_), do: "text-gray-500"

  defp status_label("critical"), do: "Crítico"
  defp status_label("warning"), do: "Alerta"
  defp status_label("ok"), do: "Normal"
  defp status_label(_), do: "Offline"

  defp temp_color(nil), do: "text-gray-600"
  defp temp_color(t) when t >= 100.0, do: "text-red-400"
  defp temp_color(t) when t >= 90.0, do: "text-yellow-400"
  defp temp_color(_), do: "text-green-400"
end
