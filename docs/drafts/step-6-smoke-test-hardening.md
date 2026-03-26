# Passo 6: Smoke Test e Hardening de Produção

**Status:** Concluído
**Data:** 2026-03-26

## 1. Objetivo

Validar o **fluxo ponta a ponta** (startup → registro → login → dashboard)
em ambiente Docker de produção, corrigindo todas as falhas encontradas
durante o smoke test manual.

---

## 2. O Que É Isso? (Não São Testes Funcionais)

O que realizamos aqui se enquadra em três categorias de engenharia:

| Categoria | O que é | O que fizemos |
|---|---|---|
| **Smoke Test** | Teste manual rápido que verifica se o sistema "liga e funciona" de ponta a ponta | Subimos o Docker, tentamos registrar, logar, acessar o dashboard — e encontramos crashes |
| **Integration Hardening** | Corrigir falhas que só aparecem quando componentes reais se conectam (não em testes unitários) | Swoosh + SMTP + Mailpit; URL gerada com porta errada; `@refresh_interval` sem assign |
| **UX Polish** | Ajustar a experiência do usuário para que o fluxo seja óbvio e sem fricção | Redirect automático, tema consistente, textos em PT-BR, link para Mailpit |

**Por que não são testes funcionais?**
Testes funcionais são automatizados (ex: Wallaby/Hound simulando cliques no browser).
O que fizemos foi **smoke test manual** — uma validação humana do fluxo real que revelou
bugs de integração impossíveis de pegar em testes unitários.

---

## 3. Bugs Encontrados e Corrigidos

### 3.1 — Swoosh Crash em Produção

**Sintoma:** Internal Server Error ao acessar qualquer página.

**Causa raiz:** O `config/prod.exs` define `config :swoosh, local: false`, que desativa
o GenServer `Swoosh.Adapters.Local`. Porém, o mailer ainda apontava para esse adapter.
Ao tentar enviar email, o GenServer não existia → crash.

**Correção:**
- Adicionado `gen_smtp` como dependência
- Configurado `Swoosh.Adapters.SMTP` em `runtime.exs`
- Adicionado Mailpit ao `docker-compose.yml` como servidor SMTP local

```elixir
# config/runtime.exs
config :w_core, WCore.Mailer,
  adapter: Swoosh.Adapters.SMTP,
  relay: System.get_env("SMTP_HOST", "mailpit"),
  port: String.to_integer(System.get_env("SMTP_PORT", "1025")),
  ssl: false,
  tls: :never,
  auth: :never
```

### 3.2 — Magic Link com URL Errada

**Sintoma:** O email continha `https://localhost:443` — connection refused.

**Causa raiz:** `runtime.exs` usava `PHX_PORT` hardcoded como 443 e scheme como https.
Em ambiente Docker local, precisamos `http://localhost:4000`.

**Correção:** Variáveis de ambiente configuráveis:

```elixir
# runtime.exs
port = String.to_integer(System.get_env("PHX_PORT", "443"))
scheme = System.get_env("PHX_SCHEME", "https")

config :w_core, WCoreWeb.Endpoint,
  url: [host: host, port: port, scheme: scheme]
```

```yaml
# docker-compose.yml
environment:
  PHX_PORT: 4000
  PHX_SCHEME: http
```

### 3.3 — Crash no Dashboard `/telemetry`

**Sintoma:** `KeyError: key :refresh_interval not found` → Internal Server Error.

**Causa raiz:** No template HEEx, `@refresh_interval` busca nos **assigns** do socket.
Porém, `@refresh_interval` era apenas um **module attribute** (`@refresh_interval 1_000`)
e nunca foi passado para o socket via `assign/3`.

**Correção:**

```elixir
# mount/3
{:ok,
 socket
 |> assign(:refresh_interval, @refresh_interval)  # ← adicionado
 |> assign(:machine_ids, machine_ids)
 |> assign(:sensors, fetch_sensors(machine_ids))
 |> assign(:last_updated, Time.utc_now()),
 layout: false}
```

> **Lição aprendida:** Em HEEx, `@var` sempre significa `assigns[:var]`.
> Module attributes de Elixir podem ser usados no código Elixir do LiveView
> (como em `mount`), mas nunca diretamente no template.

### 3.4 — Redirect Pós-Login Apontando para `/`

**Sintoma:** Após confirmar o magic link, o usuário caía na página raiz genérica
do Phoenix (com logo e "Get Started") em vez do dashboard.

**Causa raiz:** `signed_in_path/1` retornava `~p"/"`.

**Correção:**

```elixir
# user_auth.ex
defp signed_in_path(_conn), do: ~p"/telemetry"
```

Também ajustamos:
- `PageController.home/2` → redireciona para `/telemetry` (autenticado) ou `/users/log-in`
- `on_mount(:redirect_if_user_is_authenticated)` → redireciona para `/telemetry`

---

## 4. Melhorias de UX Aplicadas

### 4.1 — Página de Confirmação Redesenhada

A página `/users/log-in/:token` (confirm) usava o layout padrão do Phoenix com
textos em inglês. Redesenhada com o mesmo tema escuro industrial da tela de login:
- Botão único "Entrar no Dashboard →" (simplificado de 2 para 1)
- Visual consistente com header Planta 42 + WCore

### 4.2 — Navbar do Root Layout

A navbar global usava classes DaisyUI genéricas e textos em inglês
("Settings", "Log out"). Atualizada para:
- Tema escuro (`bg-slate-900/80`)
- Textos em PT-BR ("Configurações", "Sair")

### 4.3 — Link para Mailpit na Tela de Login

Adicionado bloco informativo condicional na tela de login que aparece quando
o adapter é SMTP, indicando onde acessar os emails (Mailpit).

---

## 5. Fluxo Final Validado

```
Usuário acessa localhost:4000
         │
         ├── Não autenticado ──▶ redirect /users/log-in
         │                        │
         │                        ├── Registrar ──▶ /users/register
         │                        │
         │                        └── Magic Link ──▶ email enviado
         │                                            │
         │                              ┌─────────────▼──────────────┐
         │                              │ Mailpit (localhost:8025)   │
         │                              │ ou /dev/mailbox (dev)      │
         │                              └─────────────┬──────────────┘
         │                                            │ clica no link
         │                                            ▼
         │                              /users/log-in/:token (confirm)
         │                                            │
         │                                  "Entrar no Dashboard →"
         │                                            │
         └── Autenticado ─────────────────────────────┘
                                                      │
                                                      ▼
                                          /telemetry (Dashboard)
                                          LiveView · ETS · 1×/s
```

---

## 6. Arquivos Modificados

| Arquivo | Mudança |
|---|---|
| `mix.exs` | Adicionado `{:gen_smtp, "~> 1.0"}` |
| `config/runtime.exs` | SMTP adapter + PHX_PORT/PHX_SCHEME configuráveis |
| `docker-compose.yml` | Serviço Mailpit + env vars |
| `lib/w_core_web/user_auth.ex` | `signed_in_path` → `/telemetry` |
| `lib/w_core_web/controllers/page_controller.ex` | Redirect condicional |
| `lib/w_core_web/live/telemetry_live/index.ex` | `assign(:refresh_interval)` |
| `lib/w_core_web/controllers/user_session_html.ex` | Helpers `smtp_mail_adapter?`, `mailpit_url` |
| `lib/w_core_web/controllers/user_session_html/new.html.heex` | Bloco Mailpit condicional |
| `lib/w_core_web/controllers/user_session_html/confirm.html.heex` | Redesign tema industrial |
| `lib/w_core_web/components/layouts/root.html.heex` | Navbar dark + PT-BR |

---

## 7. Trade-offs

| Decisão | Alternativa | Por que escolhemos |
|---|---|---|
| Mailpit no compose | Servidor SMTP real | Zero config, captura emails sem dependência externa |
| Smoke test manual | Testes E2E com Wallaby | Velocidade; Wallaby exigiria ChromeDriver no Docker |
| Botão único no confirm | Duas opções (remember/não) | Simplicidade; `remember_me=true` por padrão é seguro para app industrial interna |
| Redirect `/` → `/telemetry` | Landing page separada | Operadores querem ver dados, não uma homepage genérica |
