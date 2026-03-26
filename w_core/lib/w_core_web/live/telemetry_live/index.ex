defmodule WCoreWeb.TelemetryLive.Index do
  @moduledoc """
  Dashboard em tempo real da Planta 42 — Fase 6.
  A ORDEM IMPORTA: O visual foi refinado para transmitir profissionalismo,
  mantendo o glanceability (facilidade de leitura rápida) e o uso estratégico de cores.
  Lê exclusivamente do ETS (Memória RAM) a cada 1 segundo.
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
    machine_ids =
      Repo.all(from n in Node, select: n.machine_identifier)
      |> Enum.sort()

    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :tick)
    end

    {:ok,
     socket
     |> assign(:page_title, "Planta 42 — Dashboard Industrial")
     |> assign(:machine_ids, machine_ids)
     |> assign(:sensors, fetch_sensors(machine_ids))
     |> assign(:last_updated, Time.utc_now()),
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
    <%!-- ── CONFIGURAÇÃO GLOBAL ───────────────────────────────────────── --%>
    <div class="min-h-screen bg-slate-950 text-slate-100 font-sans antialiased" style="font-feature-settings: 'cv02', 'cv03', 'cv04', 'cv11';">

      <%!-- ── HEADER (REFRESH RATE SUTIL) ─────────────────────────────── --%>
      <header class="bg-slate-900 border-b border-slate-800 px-8 py-5 sticky top-0 z-10 shadow-lg shadow-slate-950/20">
        <div class="max-w-[90rem] mx-auto flex flex-wrap items-center justify-between gap-6">

          <div class="flex items-center gap-4">
            <span class="flex h-3 w-3 relative">
              <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"></span>
              <span class="relative inline-flex rounded-full h-3 w-3 bg-emerald-500"></span>
            </span>
            <h1 class="text-xl font-extrabold tracking-tighter text-white uppercase">
              Planta 42 <span class="text-slate-600 font-medium">|</span> <span class="text-slate-200">Telemetria Industrial</span>
            </h1>
          </div>

          <div class="flex items-center gap-8 text-sm">
            <div class="flex items-center gap-2">
              <span class="text-slate-600 border-l border-slate-700 pl-4 uppercase tracking-widest text-xs">atualizado em:</span>
              <span class="font-mono text-white tracking-wider tabular-nums">{format_time(@last_updated)}</span>
            </div>
            <div class="text-slate-700 border-l border-slate-700 pl-4">
              Refresh: <span class="text-white font-mono tabular-nums">{ @refresh_interval / 1000 }s</span>
            </div>
          </div>

        </div>
      </header>

      <%!-- ── GRID DE SENSORES (LAYOUT MODERNO) ───────────────────────── --%>
      <main class="max-w-[90rem] mx-auto px-6 py-10">
        <div class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-8">

          <div
            :for={sensor <- @sensors}
            class={["rounded-3xl p-6 transition-all duration-700", card_classes(sensor.status)]}
          >
            <%!-- Card Header --%>
            <div class={["flex items-start justify-between border-b pb-4 mb-6", card_divider_classes(sensor.status)]}>
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-2 mb-1.5">
                  <span class={["relative flex h-2.5 w-2.5", status_dot_classes(sensor.status)]}>
                    <span class={["animate-ping absolute inline-flex h-full w-full rounded-full opacity-60", status_dot_animate_classes(sensor.status)]}></span>
                    <span class={["relative inline-flex rounded-full h-2.5 w-2.5", status_dot_animate_classes(sensor.status)]}></span>
                  </span>
                  <span class={["text-xs font-semibold tracking-widest uppercase py-0.5 px-2.5 rounded-full", status_badge_classes(sensor.status)]}>
                    {status_label(sensor.status)}
                  </span>
                </div>
                <h2 class="text-base font-bold text-white tracking-tight truncate">
                  {sensor.machine_id}
                </h2>
              </div>
              <div class="text-right ml-4 flex-shrink-0">
                <div class="text-[10px] text-slate-500 uppercase tracking-widest font-medium">Eventos</div>
                <div class="text-3xl font-extrabold text-white tabular-nums tracking-tighter">{sensor.event_count}</div>
              </div>
            </div>

            <%!-- Leituras — A dica de ouro: números grandes para glanceability --%>
            <div class="space-y-4">

              <div class="bg-slate-800/40 rounded-xl px-4 py-3.5 border border-slate-700/50">
                <div class="flex justify-between items-center mb-1">
                  <div class="flex items-center gap-2 text-slate-500">
                    <%!-- Ícone Termômetro --%>
                    <svg class="w-4 h-4 text-slate-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 19V6l-2.286 2.286m0 0a2 2 0 01-2.828 0m0 0L3.172 12m14.828 6.828L18.828 17m0 0a2 2 0 012.828 0M21 12.172v6.828m0-6.828L18.828 10M11 11a4 4 0 11-8 0 4 4 0 018 0zm-1 0a3 3 0 11-6 0 3 3 0 016 0z" />
                    </svg>
                    <span class="text-xs text-slate-400 uppercase tracking-wider font-medium">Temperatura</span>
                  </div>
                  <span class={["text-xs font-semibold", temp_color(sensor.temperature)]}>
                    Limiar: 90/100 °C
                  </span>
                </div>
                <div class="flex items-baseline justify-between gap-2">
                    <span class={["font-mono font-black tabular-nums tracking-tighter text-4xl", temp_value_color(sensor.temperature)]}>
                      {format_temp(sensor.temperature)}
                    </span>
                    <span class="text-xl text-slate-400 font-medium">°C</span>
                </div>
              </div>

              <div class="bg-slate-800/40 rounded-xl px-4 py-3.5 border border-slate-700/50">
                <div class="flex justify-between items-center mb-1">
                  <div class="flex items-center gap-2 text-slate-500">
                    <%!-- Ícone Vibração --%>
                    <svg class="w-4 h-4 text-slate-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
                    </svg>
                    <span class="text-xs text-slate-400 uppercase tracking-wider font-medium">Vibração</span>
                  </div>
                </div>
                <div class="flex items-baseline justify-between gap-2">
                    <span class="font-mono font-black tabular-nums tracking-tighter text-4xl text-sky-400">
                      {format_vibration(sensor.vibration)}
                    </span>
                    <span class="text-xl text-slate-400 font-medium">mm/s</span>
                </div>
              </div>

            </div>

            <%!-- Card Footer --%>
            <div class={["mt-6 pt-3 border-t", card_divider_classes(sensor.status)]}>
              <div class="flex justify-between items-center text-xs text-slate-700">
                <span class="uppercase tracking-widest font-medium">Lida:</span>
                <span class="font-mono">{format_last_seen(sensor.last_seen_at)}</span>
              </div>
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
  # Helpers de formatação
  # ---------------------------------------------------------------------------

  defp format_time(time), do: Time.to_string(time) |> String.slice(0, 8)

  defp format_temp(nil), do: "—"
  defp format_temp(t), do: :erlang.float_to_binary(t, [{:decimals, 2}])

  defp format_vibration(nil), do: "—"
  defp format_vibration(v), do: :erlang.float_to_binary(v, [{:decimals, 2}])

  defp format_last_seen(nil), do: "aguardando dados..."
  defp format_last_seen(dt), do: NaiveDateTime.to_string(dt) |> String.slice(0, 19)

  # ---------------------------------------------------------------------------
  # Helpers de estilo — Refinados e consistentes
  # ---------------------------------------------------------------------------

  # A ORDEM IMPORTA: Crítico é agressivo e pisca, Warning é visível mas estático.
  defp card_classes("critical"), do: "border border-red-800 bg-red-950/20 shadow-lg shadow-red-950/20 animate-pulse"
  defp card_classes("warning"), do: "border border-amber-700 bg-amber-950/20 shadow-md shadow-amber-950/20"
  defp card_classes("ok"), do: "border border-slate-700 bg-slate-900/80 shadow-inner"
  defp card_classes(_), do: "border border-slate-800 bg-slate-900/40 opacity-70"

  defp card_divider_classes("critical"), do: "border-red-800/50"
  defp card_divider_classes("warning"), do: "border-amber-700/50"
  defp card_divider_classes(_), do: "border-slate-800"

  defp status_dot_classes("critical"), do: "bg-red-500"
  defp status_dot_classes("warning"), do: "bg-amber-400"
  defp status_dot_classes("ok"), do: "bg-emerald-500"
  defp status_dot_classes(_), do: "bg-slate-600"

  defp status_dot_animate_classes("critical"), do: "bg-red-400"
  defp status_dot_animate_classes("warning"), do: "bg-amber-400"
  defp status_dot_animate_classes("ok"), do: "bg-emerald-400"
  defp status_dot_animate_classes(_), do: "bg-slate-400"

  defp status_badge_classes("critical"), do: "bg-red-950/40 text-red-200"
  defp status_badge_classes("warning"), do: "bg-amber-950/40 text-amber-200"
  defp status_badge_classes("ok"), do: "bg-emerald-950/40 text-emerald-200"
  defp status_badge_classes(_), do: "bg-slate-800/40 text-slate-300"

  defp status_label("critical"), do: "Crítico"
  defp status_label("warning"), do: "Alerta"
  defp status_label("ok"), do: "Normal"
  defp status_label(_), do: "Offline"

  defp temp_color(nil), do: "text-slate-600"
  defp temp_color(t) when t >= 100.0, do: "text-red-400"
  defp temp_color(t) when t >= 90.0, do: "text-amber-400"
  defp temp_color(_), do: "text-emerald-400"

  defp temp_value_color(nil), do: "text-slate-600"
  defp temp_value_color(t) when t >= 100.0, do: "text-red-400"
  defp temp_value_color(t) when t >= 90.0, do: "text-amber-400"
  defp temp_value_color(_), do: "text-emerald-400"
end
