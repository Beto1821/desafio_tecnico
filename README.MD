# W-Core — Motor de Estado em Tempo Real

> Desafio Técnico — Web-Engenharia
> Sistema de telemetria industrial para a **Planta 42**.

---

## Arquitetura — Duas Camadas, Zero Gargalos

O W-Core foi projetado para absorver alto volume de eventos sem comprometer
a latência do dashboard. A chave é separar o **caminho quente** (leitura/escrita
em RAM) do **caminho frio** (persistência em disco), garantindo:

- **Escrita atômica O(1)** — cada evento é registrado no ETS sem locks
- **Zero contenção no banco** — o SQLite recebe apenas batch UPSERTs a cada 5s
- **Dashboard em tempo real** — leitura direto do ETS, sem queries ao banco
- **Resiliência a picos** — 10.000 eventos concorrentes sem perda de contagem

### Diagrama de Fluxo

```
Sensores (Simulator)
      │
      │  record_event/4 — escrita atômica O(1)
      ▼
┌─────────────────────────────────┐
│   Camada Quente: ETS (RAM)      │  ← absorve o tsunami de eventos
│   :w_core_telemetry_cache       │
└────────────────┬────────────────┘
                 │  tab2list a cada 5s (batch)
                 ▼
┌─────────────────────────────────┐
│   Camada Fria: SQLite (WAL)     │  ← fonte de verdade persistida
│   FlushWorker — UPSERT em lote  │
└─────────────────────────────────┘
                 │
                 │  lookup/1 — leitura O(1) no ETS
                 ▼
┌─────────────────────────────────┐
│   Dashboard LiveView            │  ← poll ETS 1×/s → diff WebSocket
│   /telemetry (autenticado)      │
└─────────────────────────────────┘
```

**Padrão Write-Behind:** eventos chegam → ETS imediatamente → banco em lote a cada 5s.
Zero locks de escrita no caminho quente.

---

## Stack

| Tecnologia | Papel |
|---|---|
| Elixir + Phoenix 1.8 | Framework principal |
| Phoenix LiveView 1.1 | Dashboard em tempo real |
| Erlang ETS | Cache de estado quente (RAM) |
| SQLite + WAL mode | Persistência local (Edge) |
| Tailwind CSS + HEEx | Componentes puros, tema industrial |
| Docker multi-stage | Empacotamento para produção |

---

## Funcionalidades Implementadas

- **Simulador de sensores** — 8 máquinas industriais, eventos a cada 500ms–2000ms
- **Cache ETS** — escrita atômica via `:ets.update_counter/4`, sem race conditions
- **FlushWorker** — UPSERT em lote a cada 5s com correção de contador pós-flush
- **Dashboard LiveView** — grid responsivo com status por cor e `animate-pulse` para críticos
- **Autenticação** — `phx.gen.auth` com proteção de LiveView via `on_mount`
- **Teste de Caos** — 10.000 eventos concorrentes, `event_count == 10.000` ✅
- **Docker** — `mix release` multi-stage com volume para persistência do SQLite

---

## 🚀 Quick Start — Docker (Recomendado)

> **Esta é a forma mais rápida de ver o sistema funcionando.**
> Um único comando sobe a aplicação + servidor de email — sem precisar
> instalar Elixir, Erlang ou qualquer dependência local.

### Pré-requisito: Docker instalado

### 1. Subir tudo com um comando

```bash
cd w_core
docker compose up --build
```

Isso inicia dois serviços:

| Serviço | URL | Descrição |
|---|---|---|
| **W-Core** | http://localhost:4000 | Aplicação Phoenix (dashboard) |
| **Mailpit** | http://localhost:8025 | Caixa de entrada dos magic links |

### 2. Cadastrar e fazer login

1. Acesse http://localhost:4000/users/register e cadastre seu email
2. Acesse http://localhost:4000/users/log-in e solicite o magic link
3. Abra http://localhost:8025 (Mailpit) → clique no email → clique no link
4. Pronto — você será autenticado e redirecionado ao **Dashboard de Telemetria**

### 3. Dashboard

O painel em http://localhost:4000/telemetry exibe em tempo real o estado de
todos os 8 sensores da Planta 42, atualizando a cada segundo direto do ETS.

---

## Desenvolvimento Local (alternativa)

<details>
<summary>Expandir instruções para rodar sem Docker</summary>

### Pré-requisitos

- Elixir 1.19+
- Erlang/OTP 28+

### 1. Instalar dependências e configurar o banco

```bash
cd w_core
mix setup
```

Este comando executa em sequência:
- `mix deps.get` — baixa dependências
- `mix ecto.create` — cria o banco SQLite
- `mix ecto.migrate` — roda as migrations
- `mix run priv/repo/seeds.exs` — popula os 8 nós da Planta 42

### 2. Iniciar o servidor

```bash
iex -S mix phx.server
```

### 3. Criar um operador e fazer login

O sistema usa **magic link** (sem senha) — o login é feito via link enviado por email.

**3.1 — Cadastro:**

Acesse `http://localhost:4000/users/register` e informe seu email.

**3.2 — Login:**

Acesse `http://localhost:4000/users/log-in`, informe o email cadastrado e clique em **Log in**.

**3.3 — Confirmar o magic link:**

Em desenvolvimento, os emails ficam na caixa local:

```
http://localhost:4000/dev/mailbox
```

Clique no email recebido → você será autenticado e redirecionado ao dashboard.

### 4. Acessar o dashboard

```
http://localhost:4000/telemetry
```

</details>

---

## Testes

### Rodar todos os testes

```bash
cd w_core
mix test
```

### Rodar o Teste de Caos (concorrência)

```bash
mix test test/w_core/telemetry/chaos_test.exs --trace
```

Resultado esperado:
```
✅ 10.000 eventos concorrentes não perdem nenhuma contagem no ETS (95ms)
✅ contadores de múltiplas máquinas são independentes e precisos    (86ms)
```

---

## Estrutura do Projeto

```
desafio_tecnico/
├── CLAUDE.md                         # Regras de Ouro (System Prompt)
├── README.MD                         # Este arquivo
├── docs/
│   ├── drafts/                       # Documentação por passo (Regra de Ouro)
│   │   ├── PLANNING.md               # Roadmap e visão geral
│   │   ├── 001-architecture-overview.md
│   │   ├── 002-database-schema.md
│   │   ├── step-1-foundation.md      # Fundação + SQLite + Auth
│   │   ├── step-2-otp-ets.md         # Motor OTP + ETS
│   │   ├── step-3-liveview-ds.md     # Dashboard LiveView
│   │   ├── step-4-tests.md           # Teste de Caos (10k eventos)
│   │   ├── step-5-infra-arch.md      # Docker + Release
│   │   └── step-6-smoke-test-hardening.md  # Hardening produção
│   └── study/                        # Guia de estudo para entrevista
└── w_core/                           # Aplicação Phoenix
    ├── docker-compose.yml            # w_core + Mailpit
    ├── Dockerfile                    # Multi-stage release
    ├── lib/
    │   ├── w_core/
    │   │   ├── application.ex        # Supervisor tree
    │   │   ├── repo.ex               # SQLite + WAL config
    │   │   ├── accounts/             # Autenticação (phx.gen.auth)
    │   │   └── telemetry/
    │   │       ├── cache.ex           # GenServer dono do ETS
    │   │       ├── flush_worker.ex    # Write-Behind para SQLite
    │   │       ├── simulator.ex       # Gerador de eventos (8 processos)
    │   │       ├── node.ex            # Schema: sensores cadastrados
    │   │       └── node_metric.ex     # Schema: estado consolidado
    │   └── w_core_web/
    │       ├── user_auth.ex           # Plugs + on_mount LiveView
    │       └── live/
    │           └── telemetry_live/
    │               └── index.ex       # Dashboard LiveView
    ├── priv/repo/
    │   ├── migrations/               # Telemetry + Auth tables
    │   └── seeds.exs                 # 8 sensores da Planta 42
    └── test/
        └── w_core/telemetry/
            └── chaos_test.exs         # Teste de caos: 10k eventos
```

---

## Árvore de Supervisão OTP

```
WCore.Application (:one_for_one)
├── WCoreWeb.Telemetry          ← métricas BEAM
├── WCore.Repo                  ← conexão SQLite (WAL mode)
├── Ecto.Migrator               ← migrations automáticas no boot
├── DNSCluster                  ← descoberta de nós (clustering)
├── Phoenix.PubSub               ← barramento de mensagens
├── WCore.Telemetry.Cache       ← GenServer owner do ETS (inicia primeiro)
├── WCore.Telemetry.FlushWorker ← Write-Behind: ETS → SQLite a cada 5s
├── WCore.Telemetry.Simulator   ← 8 processos leves, 1 por sensor
└── WCoreWeb.Endpoint           ← HTTP + WebSocket (Bandit)
```

**Estratégia `:one_for_one`:** se o `FlushWorker` falhar, somente ele é
reiniciado. O `Cache` (e sua tabela ETS) permanece intacto — eventos continuam
sendo acumulados durante o restart, sem perda de dados em memória.

---

## Decisões Arquiteturais

Cada decisão de trade-off está documentada em `/docs/drafts/`. Resumo:

| Decisão | Alternativa | Motivo |
|---|---|---|
| ETS como cache quente | GenServer state | Escrita direta sem mailbox, `read_concurrency` |
| Write-Behind (5s) | Write-Through | Zero locks no caminho quente |
| Polling LiveView (1s) | PubSub por evento | O(usuários) vs O(usuários × eventos/s) |
| SQLite + WAL | PostgreSQL | Edge computing, zero dependências externas |
| `update_counter` atômico | Leitura-escrita manual | Previne race condition no contador |
| `live_session` + `on_mount` | Plug apenas | Plugs não protegem WebSockets |
| `:one_for_one` Supervisor | `:rest_for_one` | Falha isolada sem efeito cascata |
