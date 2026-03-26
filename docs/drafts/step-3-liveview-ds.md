# Draft / Step 3: Dashboard em Tempo Real — LiveView + ETS

**Status:** Implementado
**Data:** 2026-03-26
**Autor:** Adalberto
**Depende de:** Step 1 (fundação), Step 2 (Cache + FlushWorker)

---

## 1. O que foi implementado

O dashboard de telemetria da Planta 42: uma interface LiveView que exibe em
tempo real o estado de todos os 8 sensores, lendo diretamente do ETS sem
nenhuma query ao banco de dados.

| Componente | Arquivo | Papel |
|---|---|---|
| Dashboard LiveView | `lib/w_core_web/live/telemetry_live/index.ex` | Página principal autenticada |
| Rota protegida | `lib/w_core_web/router.ex` | `live_session` + `on_mount` |
| Auth hooks | `lib/w_core_web/user_auth.ex` | Valida token no handshake WS |

---

## 2. Autenticação e Proteção do WebSocket

### O problema: Plugs não protegem LiveView

Em Phoenix, plugs rodam apenas no request HTTP inicial. Após o upgrade para
WebSocket, novos frames **não** passam pela pipeline de plugs. Se usássemos
apenas `:require_authenticated_user` como plug, um usuário poderia abrir a
página autenticado, perder a sessão, e continuar vendo dados em tempo real.

### A solução: `live_session` + `on_mount`

```elixir
# router.ex
live_session :require_authenticated_user,
  on_mount: [{WCoreWeb.UserAuth, :require_authenticated_user}] do
  live "/telemetry", TelemetryLive.Index
end
```

O callback `on_mount` é executado **dentro do processo LiveView**, tanto na
montagem inicial quanto em navegações client-side. Ele valida o token da sessão
e redireciona para `/users/log-in` se o usuário não estiver autenticado.

**Trade-off:** o `on_mount` adiciona uma verificação por conexão LiveView.
Em um dashboard com 50 usuários simultâneos, são 50 verificações na
montagem — overhead negligível comparado à alternativa de expor dados sem
autenticação.

---

## 3. Estratégia de Reatividade: Polling no ETS vs PubSub

Esta é a decisão arquitetural mais importante do Step 3.

### Alternativa descartada: PubSub por evento

```
Sensor → Cache.record_event → PubSub.broadcast("telemetry:update") → LiveViews
```

Sob metralhadora de dados (8 sensores × ~1 evento/s = 8 eventos/s mínimo,
até centenas em cenários reais), cada evento geraria:
1. **N broadcasts** (1 por LiveView conectado)
2. **N re-renderizações** no navegador
3. **N diffs WebSocket** enviados

Com 50 operadores abertos: `8 eventos/s × 50 = 400 mensagens/s`. A maioria
seria redundante — o operador não distingue atualizações a cada 125ms.

### Solução adotada: Polling Local (Pull)

```
LiveView → :timer.send_interval(1000) → Cache.lookup(machine_ids) → assign → diff
```

O LiveView "acorda" a cada 1 segundo, lê o ETS (memória RAM, O(1) por chave)
e atualiza os assigns. O Phoenix calcula o diff e envia ao navegador **apenas
o que mudou**.

**Complexidade comparada:**

| Métrica | PubSub por evento | Polling 1s |
|---|---|---|
| Mensagens WS / segundo | O(usuários × eventos/s) | O(usuários) |
| Com 50 users, 8 sensors | 400 msg/s | 50 msg/s |
| Latência percebida | < 100ms | ≤ 1000ms |
| CPU do navegador | Alta (re-render constante) | Baixa (1 render/s) |

**Trade-off explícito:** sacrificamos latência sub-segundo (imperceptível para
operadores humanos) por uma carga 8× menor na rede e no navegador.

### Por que 1 segundo?

- **Percepção humana:** operadores não reagem a mudanças abaixo de ~300ms
- **Custo de rede:** 1 diff WS/s × 50 users = 50 msgs/s (trivial)
- **Coerência visual:** animações CSS (`animate-pulse` para críticos) precisam
  de ao menos 1s para serem percebidas
- **Configurável:** o valor é um `@refresh_interval` no módulo, alterável sem
  refatoração

---

## 4. Implementação do `mount` e `handle_info`

### Mount — carregamento inicial

```elixir
@refresh_interval 1_000

def mount(_params, _session, socket) do
  machine_ids = WCore.Telemetry.list_machine_ids()
  metrics = Cache.lookup(machine_ids)

  if connected?(socket) do
    :timer.send_interval(@refresh_interval, self(), :refresh)
  end

  {:ok,
   socket
   |> assign(:metrics, metrics)
   |> assign(:machine_ids, machine_ids)
   |> assign(:refresh_interval, @refresh_interval)}
end
```

**Detalhe:** o `if connected?(socket)` evita que o timer seja criado durante
a renderização estática (SEO/primeira pintura HTML). O timer só inicia após
o WebSocket conectar — impede timers órfãos.

### handle_info — atualização periódica

```elixir
def handle_info(:refresh, socket) do
  metrics = Cache.lookup(socket.assigns.machine_ids)
  {:noreply, assign(socket, :metrics, metrics)}
end
```

A cada tick, o LiveView lê o ETS e re-atribui `:metrics`. O Phoenix diff
engine compara o estado anterior e envia ao navegador **apenas os campos
que mudaram** — se nenhum sensor mudou de status, zero bytes são enviados.

---

## 5. Componentes HEEx e Design Visual

### Grid responsivo

```heex
<div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4">
  <div :for={m <- @metrics} class={card_class(m.status)}>
    ...
  </div>
</div>
```

Layout adapta de 1 coluna (mobile) a 4 colunas (desktop largo). Componentes
HEEx puros — sem bibliotecas de UI externas.

### Código de cores por status

| Status | Cor | Efeito | Motivo |
|---|---|---|---|
| `critical` | Vermelho (`red-500`) | `animate-pulse` pulsante | Atenção imediata do operador |
| `warning` | Âmbar (`amber-500`) | Estático | Alerta sem urgência |
| `ok` | Slate (`slate-600`) | Nenhum | Estado normal, não distrai |
| `offline` | Cinza dim | Opacidade reduzida | Sensor inativo |

O `animate-pulse` em sensores críticos é intencional: em uma sala de controle,
um card pulsando em vermelho chama atenção periférica. A decisão de usar
animação apenas para `critical` (e não para `warning`) evita fadiga visual.

### Informações exibidas por sensor

- **Identificador** da máquina (ex: `turbina-01`)
- **Status** com badge colorido
- **Temperatura** (°C, 2 casas decimais)
- **Vibração** (mm/s, 2 casas decimais)
- **Eventos processados** (contador acumulativo)
- **Última leitura** (timestamp truncado a segundos)

---

## 6. Fluxo completo: do sensor ao pixel

```
Simulator (8 processos)
    │ spawn/loop
    ▼
Cache.record_event/4          ← escrita atômica no ETS
    │
    │   [cada 1s]
    ▼
LiveView.handle_info(:refresh)
    │
    ▼
Cache.lookup(machine_ids)     ← leitura O(1) no ETS
    │
    ▼
assign(:metrics, new_data)
    │
    ▼
Phoenix Diff Engine            ← calcula delta do HEEx
    │
    ▼
WebSocket → Navegador          ← somente campos que mudaram
```

O banco de dados **nunca** é consultado para renderizar o dashboard. O SQLite
participa apenas do Write-Behind (Step 2) para persistência a cada 5 segundos.

---

## 7. Trade-offs e limitações

| Decisão | O que ganhamos | O que sacrificamos |
|---|---|---|
| Polling 1s vs PubSub | 8× menos tráfego WS | Latência máxima de 1s |
| Leitura do ETS (não do banco) | Zero queries SQL no render | Dados perdem-se se processo Cache morrer |
| `animate-pulse` só para critical | Foco visual claro | Warnings podem passar despercebidos |
| Componentes HEEx inline | Zero dependências UI | Sem design system reutilizável (fora do escopo) |

### Mitigação para perda de ETS

Se o processo `Cache` morrer, o Supervisor o reinicia e a tabela ETS é
recriada vazia. O `FlushWorker` (que é outro child) continua vivo e, no
próximo ciclo, o Simulator repopula o ETS. Janela de dados vazios: ~2 segundos
no pior caso.
