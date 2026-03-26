# Estudo: LiveView, Autenticação e WebSockets

> Pontos de defesa para a entrevista técnica.

---

## Pergunta: "Como o LiveView funciona por baixo dos panos?"

LiveView usa uma conexão WebSocket persistente para enviar apenas as **diferenças
do DOM** (diffs) ao invés de recarregar a página inteira.

**Ciclo de vida:**

```
1. Usuário acessa /telemetry (HTTP GET)
   → Phoenix renderiza HTML estático (dead render)
   → Página chega ao browser com dados iniciais

2. JavaScript do Phoenix conecta via WebSocket
   → LiveView monta novamente (live render) com connected?() = true
   → :timer.send_interval inicia

3. A cada 1s → handle_info(:tick)
   → fetch_sensors() lê 8 chaves do ETS
   → assign(:sensors, novo_valor)
   → LiveView engine compara assigns antigos vs novos
   → Gera um diff mínimo (ex: apenas o número de eventos e o status mudaram)
   → Envia diff via WebSocket (geralmente < 1KB)
   → Browser aplica o patch no DOM sem refresh
```

**Por que isso é melhor que polling HTTP:**
- HTTP polling: browser faz GET a cada 1s → resposta HTML completa → re-renderiza tudo
- LiveView: conexão aberta → apenas bytes que mudaram → sem flickering, sem recarregamento

---

## Pergunta: "Por que usamos polling de 1s no LiveView em vez de PubSub?"

Esta é uma das decisões arquiteturais mais importantes para defender.

**O problema do PubSub por evento:**
```
Simulator: 8 sensores × ~1,5 eventos/s = ~12 broadcasts/s
Com 50 usuários no dashboard: 12 × 50 = 600 mensagens WebSocket/s

Em pico (500ms por sensor): 16 × 50 = 800 mensagens WebSocket/s
→ Overhead de serialização + renderização no browser a cada 62ms
```

**Nossa solução (polling local no ETS):**
```
Independente de quantos sensores ou frequência:
  50 usuários × 1 poll/s = 50 leituras ETS/s
  Cada leitura: 8 × O(1) = constante

Complexidade: O(usuários) — não O(usuários × eventos)
```

**Quando PubSub seria melhor:**
- Eventos raros e críticos (ex: alarme de incêndio) — não queremos esperar 1s
- Dados que mudam de forma imprevisível (chat, notificações)
- Quando precisamos de latência < 100ms na UI

**Nossa tolerância:** 1 segundo de atraso é aceitável para um painel de
monitoramento industrial. Um operador não precisa ver cada leitura de 500ms
— precisa ver o estado atual a cada segundo.

---

## Pergunta: "O que é `connected?/1` e por que verificamos isso no mount?"

O LiveView passa pelo `mount/3` duas vezes:

```
1ª vez (dead render — HTTP):
  connected?(socket) = false
  → Renderiza HTML estático para o browser
  → NÃO iniciamos o timer aqui

2ª vez (live render — WebSocket):
  connected?(socket) = true
  → Agora sim iniciamos o :timer.send_interval
```

**Por que isso importa:**
Se não checássemos `connected?`, criaríamos um timer na renderização HTTP
que nunca seria cancelado (processo órfão). Com a checagem:
- Dead render: sem timer, sem queries ao ETS (ou com dados iniciais)
- Live render: timer ativo, atualizações em tempo real

---

## Pergunta: "Como funciona a autenticação em rotas LiveView?"

Esta é uma **pegadinha comum** de entrevista. Plugs de Conn **não protegem
LiveViews após o upgrade para WebSocket**.

**O problema:**
```
HTTP GET /telemetry
  → Pipeline Plug roda: fetch_session, require_authenticated_user
  → Se não autenticado: redirect para /login ✅

WebSocket upgrade (após HTTP):
  → Pipeline Plug NÃO roda no WebSocket
  → Se alguém conectar diretamente via WS sem sessão válida?
  → Sem proteção adicional: acesso liberado ❌
```

**Nossa solução — `live_session` + `on_mount`:**
```elixir
live_session :require_authenticated_user,
  on_mount: [{WCoreWeb.UserAuth, :require_authenticated_user}] do
  live "/telemetry", TelemetryLive.Index
end
```

O callback `on_mount` executa **no momento do mount do LiveView via WebSocket**.
Ele lê o token da session (cookie criptografado), valida no banco, e:
- Token válido → `{:cont, socket}` → LiveView monta
- Token inválido → `{:halt, redirect("/users/log-in")}` → conexão encerrada

**Por que `live_session` também importa:**
Todas as rotas dentro de um `live_session` compartilham o mesmo processo de
sessão. Navegação entre elas reutiliza a conexão WebSocket existente sem
re-autenticar.

---

## Pergunta: "O que é `layout: false` e por que usamos no dashboard?"

Por padrão, LiveViews são renderizados dentro do layout `Layouts.app`, que
inclui navbar e `max-w-2xl` (largura máxima de 672px — muito estreito para um grid).

```elixir
{:ok, socket, layout: false}
```

`layout: false` desativa apenas o **inner layout** (`Layouts.app`).
O **root layout** (`root.html.heex`) continua sendo usado — ele carrega:
- `app.css` (Tailwind)
- `app.js` (Phoenix LiveView socket)
- `<meta name="csrf-token">`

Resultado: dashboard ocupa 100% da largura da tela, com grid responsivo
de 1 a 4 colunas dependendo do viewport.

---

## Pergunta: "Como o phx.gen.auth funciona? O que ele gera?"

`mix phx.gen.auth Accounts User users` gera um sistema completo de autenticação:

**Contexto `Accounts`:**
- `User` — schema com email + hash de senha (bcrypt)
- `UserToken` — tokens de sessão (HTTP) e magic links
- `Scope` — abstração de "quem está logado" (permite multi-tenancy futuro)
- Funções: `register_user`, `get_user_by_email_and_password`, `generate_user_session_token`

**Controllers:**
- `UserRegistrationController` — cadastro
- `UserSessionController` — login/logout
- `UserSettingsController` — troca de email/senha

**`UserAuth` (plugs + on_mount):**
- `fetch_current_scope_for_user/2` — plug que lê o token da sessão em cada request
- `require_authenticated_user/2` — plug para controllers
- `on_mount/4` — callback para LiveViews (adicionamos manualmente)

**Segurança embutida:**
- Senhas com bcrypt (hash + salt automático)
- Tokens de sessão com validade de 14 dias
- Renovação automática de token após 7 dias de uso
- Proteção contra session fixation (renew_session)

---

## Pergunta: "Como o Tailwind funciona no Phoenix?"

O Phoenix usa o `tailwind` Hex package (wrapper do binário Tailwind CLI).

```bash
mix tailwind w_core          # compila durante desenvolvimento
mix tailwind w_core --minify # compila e minifica para produção
```

O Tailwind escaneia os arquivos `.ex` e `.heex` em busca de classes usadas e
gera um CSS contendo **apenas** as classes presentes no código (purging).
Resultado: arquivo CSS de ~10KB em produção em vez de ~3MB do Tailwind completo.

**Por que `animate-pulse` funciona sem configuração:**
`animate-pulse` é uma classe nativa do Tailwind que gera uma animação CSS
de opacidade (0.5 → 1 → 0.5). Para sensores críticos, aplicamos no `div` do
card inteiro — o operador vê o card pulsando, indicando atenção imediata.
