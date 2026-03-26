# W-Core — Motor de Estado em Tempo Real

> Desafio Técnico — Web-Engenharia
> Sistema de telemetria industrial para a **Planta 42**.

---

## O Problema

O sistema legado da Planta 42 colapsava sob carga: cada pulso de sensor gerava
um INSERT individual no banco, causando lock de escrita constante, atraso de
minutos no painel de operações e falsos positivos paralisando a produção.

## A Solução — Arquitetura de Duas Camadas

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
| Tailwind CSS + DaisyUI | Interface industrial |
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

## Pré-requisitos

- Elixir 1.19+
- Erlang/OTP 28+
- Docker (opcional, apenas para produção)

---

## Como Rodar Localmente

### 1. Instalar dependências e configurar o banco

```bash
cd w_core
mix setup
```

Este comando executa em sequência:
- `mix deps.get` — baixa dependências
- `mix ecto.create` — cria o banco SQLite
- `mix ecto.migrate` — roda as migrations
- `run priv/repo/seeds.exs` — popula os 8 nós da Planta 42

### 2. Iniciar o servidor

```bash
iex -S mix phx.server
```

### 3. Criar um operador

Acesse `http://localhost:4000/users/register` e cadastre um usuário.

### 4. Acessar o dashboard

Acesse `http://localhost:4000/telemetry` e faça login.

O painel exibe em tempo real o estado de todos os sensores, atualizando a cada segundo.

---

## Como Rodar com Docker

### Build da imagem

```bash
cd w_core
docker build -t w_core:latest .
```

### Executar o container

```bash
docker run \
  -v /data/planta42:/data \
  -e DATABASE_PATH=/data/w_core_prod.db \
  -e SECRET_KEY_BASE=$(mix phx.gen.secret) \
  -e PHX_HOST=localhost \
  -p 4000:4000 \
  w_core:latest
```

> O diretório `/data/planta42` no host persiste o banco entre reinícios do container.

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
├── docs/
│   ├── drafts/               # Documentação por passo (Regra de Ouro)
│   │   ├── step-1-foundation.md
│   │   ├── step-2-otp-ets.md
│   │   ├── step-3-liveview-ds.md
│   │   ├── step-4-tests.md
│   │   └── step-5-infra-arch.md
│   └── study/                # Guia de estudo para entrevista técnica
└── w_core/                   # Aplicação Phoenix
    ├── lib/
    │   ├── w_core/
    │   │   ├── accounts/     # Autenticação (phx.gen.auth)
    │   │   └── telemetry/
    │   │       ├── cache.ex          # GenServer dono do ETS
    │   │       ├── flush_worker.ex   # Write-Behind para SQLite
    │   │       ├── simulator.ex      # Gerador de eventos
    │   │       ├── node.ex           # Schema: sensores cadastrados
    │   │       └── node_metric.ex    # Schema: estado atual
    │   └── w_core_web/
    │       └── live/
    │           └── telemetry_live/
    │               └── index.ex      # Dashboard LiveView
    ├── test/
    │   └── w_core/telemetry/
    │       └── chaos_test.exs        # Teste de caos: 10k eventos
    └── Dockerfile
```

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
