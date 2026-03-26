# Draft / Step 1: Fundação do Projeto — Phoenix, SQLite e Autenticação

**Status:** Implementado
**Data:** 2026-03-25
**Autor:** Adalberto

---

## 1. O que foi implementado

A base completa do sistema: framework, banco de dados otimizado para alta
concorrência, modelagem de domínio e autenticação de operadores.

| Componente | Arquivo / Módulo | Papel |
|---|---|---|
| Aplicação Phoenix | `w_core/` | Projeto gerado com `--database sqlite3` |
| Repo customizado | `lib/w_core/repo.ex` | WAL mode + cache 64MB + temp em RAM |
| Schema `Node` | `lib/w_core/telemetry/node.ex` | Cadastro estático dos sensores |
| Schema `NodeMetric` | `lib/w_core/telemetry/node_metric.ex` | Estado consolidado (UPSERT target) |
| Migration | `priv/repo/migrations/*_create_telemetry_tables.exs` | Tabelas + índices |
| Seeds | `priv/repo/seeds.exs` | 8 sensores da Planta 42 (idempotente) |
| Autenticação | `phx.gen.auth` | Magic link, Users + Tokens |

---

## 2. Decisões Técnicas e Trade-offs

### 2.1 Framework e Stack

**Phoenix 1.8 + LiveView 1.1** — escolhidos pela capacidade nativa de
atualizações em tempo real via WebSockets, sem necessidade de SPAs (React/Vue).
O LiveView permite que o servidor mantenha o estado e envie diffs mínimos ao
navegador, eliminando APIs REST intermediárias.

**SQLite3** — conforme requisito do desafio. Ideal para edge computing (zero
dependências externas), mas traz uma limitação fundamental: apenas uma escrita
por vez. Toda a arquitetura do sistema foi desenhada para contornar essa
restrição.

### 2.2 O Desafio de Performance: WAL Mode

O comportamento padrão do SQLite bloqueia **leituras** durante **escritas**.
Em telemetria de alta frequência, isso travaria tanto o dashboard quanto a
ingestão.

**Solução:** o `Repo.init/2` foi customizado para forçar PRAGMAs de performance:

```elixir
def init(_type, config) do
  config = Keyword.merge(config, [
    journal_mode: :wal,       # Write-Ahead Logging → leituras e escritas simultâneas
    cache_size: -64_000,      # 64MB de cache in-memory (negativo = KB)
    temp_store: :memory,      # Tabelas temporárias em RAM
    pool_size: 5              # Pool pequeno (SQLite trava na escrita)
  ])
  {:ok, config}
end
```

| PRAGMA | Padrão | Configurado | Efeito |
|---|---|---|---|
| `journal_mode` | DELETE | WAL | Leituras não bloqueiam durante escrita |
| `cache_size` | -2000 (2MB) | -64000 (64MB) | Mais dados em RAM, menos I/O |
| `temp_store` | DEFAULT (disco) | MEMORY | Sorts e joins temporários em RAM |
| `pool_size` | 5 | 5 | Limita conexões (SQLite não ganha com pool grande) |

**Trade-off:** WAL mode consome mais memória e gera arquivos `.wal` no disco.
Para um sistema edge com 8 sensores, o overhead é desprezível. Em escala de
milhares de sensores, consideraríamos PostgreSQL.

### 2.3 Modelagem de Dados — Estado Consolidado vs. Time-Series

**Decisão crítica:** armazenamos apenas o **último estado conhecido** de cada
sensor (1 linha por sensor na `node_metrics`), em vez de uma série temporal com
cada leitura individual.

```
Alternativa A (Time-Series):   nodes → node_readings (1 linha por evento)
Alternativa B (Consolidado):   nodes → node_metrics  (1 linha por sensor)  ← escolhido
```

| Critério | Time-Series | Consolidado |
|---|---|---|
| Volume de dados | Cresce indefinidamente | Fixo (N sensores) |
| Escrita | INSERT (append) | UPSERT (replace) |
| Leitura do dashboard | `SELECT ... ORDER BY timestamp DESC LIMIT 1` por sensor | `SELECT * FROM node_metrics` direto |
| Histórico | Completo | Apenas último estado |

**Justificativa:** o desafio exige um dashboard mostrando o estado **atual**.
O ETS já serve como buffer de alta velocidade. O banco precisa apenas persistir
o consolidado para sobreviver a reinícios. Histórico completo pode ser adicionado
futuramente com uma tabela auxiliar sem impactar o caminho quente.

### 2.4 Schemas Ecto

**`Node`** — registro estático dos sensores:

```elixir
schema "nodes" do
  field :machine_identifier, :string    # ex: "turbina-01"
  field :location, :string              # ex: "Setor A - Linha 1"
  has_one :metrics, WCore.Telemetry.NodeMetric
  timestamps()
end
```

**`NodeMetric`** — estado consolidado (alvo do UPSERT):

```elixir
schema "node_metrics" do
  field :status, :string, default: "unknown"
  field :total_events_processed, :integer, default: 0
  field :last_payload, :map             # JSON flexível por tipo de sensor
  field :last_seen_at, :naive_datetime
  belongs_to :node, WCore.Telemetry.Node
  timestamps()
end
```

O campo `last_payload` usa `:map` (JSON no SQLite) para suportar diferentes
estruturas de payload — turbinas enviam RPM e pressão, bombas enviam vazão e
temperatura. Sem schema rígido para o payload.

### 2.5 Seeds — Dados Idempotentes

O arquivo `seeds.exs` popula 8 sensores da Planta 42 com payloads realistas.
Usa `Repo.get_by` antes de inserir — re-executar `mix run priv/repo/seeds.exs`
nunca duplica dados.

### 2.6 Autenticação — `phx.gen.auth`

Gerada com `mix phx.gen.auth Accounts User users`. O sistema usa **magic link**
(login sem senha): o operador recebe um link por email, clica, e é autenticado.

A autenticação protege o dashboard via `live_session` + `on_mount`, garantindo
que o handshake WebSocket do LiveView também seja validado (plugs HTTP não
protegem WebSockets após a conexão inicial).

---

## 3. Migration: Estrutura SQL

```elixir
create table(:nodes) do
  add :machine_identifier, :string, null: false
  add :location, :string, null: false
  timestamps()
end
create unique_index(:nodes, [:machine_identifier])

create table(:node_metrics) do
  add :node_id, references(:nodes, on_delete: :delete_all), null: false
  add :status, :string, default: "unknown"
  add :total_events_processed, :integer, default: 0
  add :last_payload, :map
  add :last_seen_at, :naive_datetime, null: false
  timestamps()
end
create unique_index(:node_metrics, [:node_id])
create index(:node_metrics, [:status])
```

**Índices:**
- `unique_index(:nodes, [:machine_identifier])` — impede sensores duplicados
- `unique_index(:node_metrics, [:node_id])` — garante 1:1 e serve como target do UPSERT
- `index(:node_metrics, [:status])` — filtragem rápida por status (ex: "listar todos os críticos")

---

## 4. O que esta fundação habilita

Com o banco não-bloqueante (WAL) e a modelagem de UPSERT pronta, o Step 2
pode implementar o motor de ingestão (ETS + FlushWorker) com a garantia de que:

1. O UPSERT em lote no `node_metrics` nunca vai colidir com leituras do dashboard
2. O payload flexível (JSON) aceita qualquer estrutura de sensor
3. A autenticação já protege o endpoint LiveView que será criado no Step 3
