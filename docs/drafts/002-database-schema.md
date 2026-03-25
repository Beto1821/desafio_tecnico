# Draft 002: Schema do Banco de Dados e Estratégia de Persistência

**Status:** Proposto
**Data:** 2026-03-25
**Autor:** Adalberto
**Depende de:** Draft 001 (Arquitetura Ingestor-Worker)

---

## 1. Contexto e Problema

O Draft 001 definiu que usaremos um padrão de duas camadas: **ETS (memória)** para absorver
o tsunami de eventos em tempo real e **SQLite** como fonte de verdade durável. Este draft
define o contrato de dados de cada camada.

**A Pergunta Central:** Como estruturar o SQLite para suportar escritas em lote sem criar
o gargalo que levou ao colapso do sistema legado da Planta 42?

---

## 2. Decisão de Design: "Estado Consolidado" vs. "Série Temporal Bruta"

Esta é a decisão mais importante deste draft.

### Opção A — Gravar cada evento (Série Temporal Bruta)

```sql
CREATE TABLE sensor_events (
  id          INTEGER PRIMARY KEY,
  node_id     INTEGER NOT NULL,
  payload     TEXT NOT NULL,
  status      TEXT NOT NULL,
  recorded_at DATETIME NOT NULL
);
-- Resultado: Milhares de INSERTs por segundo → o mesmo gargalo do sistema legado.
```

**Custo:** Alta taxa de escrita → lock de escrita no SQLite → atraso no dashboard.

### Opção B — Gravar apenas o último estado por sensor (Estado Consolidado) ✅

Em vez de acumular eventos históricos, realizamos um `UPSERT` que **sobrescreve** o registro
do sensor com seu estado mais recente. A tabela `node_metrics` tem exatamente **1 linha por sensor**.

**Por que essa decisão é correta para este desafio:**
- O requisito crítico é: *"a tela deve piscar em tempo real na falha de uma máquina"*.
  Isso exige saber o **estado atual**, não o histórico completo.
- O SQLite é um banco embutido, não um banco de série temporal (ex: InfluxDB, TimescaleDB).
  Forçá-lo a ser um seria desconsiderar suas limitações de I/O em disco.
- O histórico total de eventos *vive no ETS* enquanto a aplicação está rodando. O SQLite
  é o "diário de bordo" do último estado para sobreviver a reinicializações.

**Trade-off explícito:** Perdemos o histórico granular de eventos após uma reinicialização.
  Se o requisito evoluir para "mostre a curva de temperatura das últimas 24h", precisaríamos
  revisar para uma abordagem híbrida (estado consolidado + tabela de histórico com retenção limitada).

---

## 3. Schema SQLite (Ecto Migrations)

### 3.1 Tabela `nodes` — Registro Estático de Sensores

```sql
CREATE TABLE nodes (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  machine_identifier TEXT    NOT NULL UNIQUE,  -- Ex: "TURBINE-42-A", "PUMP-07-B"
  location           TEXT    NOT NULL,          -- Ex: "Setor A / Linha 3"
  inserted_at        DATETIME NOT NULL,
  updated_at         DATETIME NOT NULL
);

CREATE INDEX idx_nodes_machine_identifier ON nodes(machine_identifier);
```

**Por que `machine_identifier` é UNIQUE e indexado:**
O GenServer precisará fazer lookup por `machine_identifier` ao receber um heartbeat.
Um índice aqui garante O(log n) na busca, evitando full table scan.

### 3.2 Tabela `node_metrics` — Estado Consolidado (Tabela Quente)

```sql
CREATE TABLE node_metrics (
  id                     INTEGER PRIMARY KEY AUTOINCREMENT,
  node_id                INTEGER NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  status                 TEXT    NOT NULL DEFAULT 'unknown',
  -- 'ok' | 'warning' | 'critical' | 'unknown'
  total_events_processed INTEGER NOT NULL DEFAULT 0,
  last_payload           TEXT,  -- JSON do último evento recebido
  last_seen_at           DATETIME NOT NULL,
  inserted_at            DATETIME NOT NULL,
  updated_at             DATETIME NOT NULL,

  CONSTRAINT uq_node_metrics_node_id UNIQUE (node_id)
  -- Garante 1 linha por sensor. É a âncora do UPSERT.
);

CREATE INDEX idx_node_metrics_status      ON node_metrics(status);
CREATE INDEX idx_node_metrics_last_seen   ON node_metrics(last_seen_at);
```

**Por que cada índice:**
- `status`: O dashboard vai filtrar por `WHERE status = 'critical'` frequentemente.
- `last_seen_at`: Detectar sensores "mortos" (sem heartbeat há mais de X segundos) exige
  ordenação por timestamp.

**A constraint `UNIQUE(node_id)` é a peça-chave:** ela é o que permite o padrão UPSERT
(`INSERT OR REPLACE` / `ON CONFLICT DO UPDATE`) sem duplicar dados.

---

## 4. Schema ETS — Camada de Memória (Erlang Term Storage)

A tabela ETS é onde os dados vivem **antes** de serem consolidados no SQLite. Ela opera
em microssegundos, sem locks de disco.

```elixir
# Criado na inicialização do GenServer supervisor
:ets.new(:w_core_telemetry_cache, [
  :set,            # Tipo: chave única, sem duplicatas. O(1) para lookup/update.
  :public,         # Qualquer processo pode ler/escrever (necessário para o Worker de flush).
  :named_table,    # Acesso por nome global em vez de referência de tabela.
  read_concurrency: true   # Otimização para múltiplos leitores simultâneos (ex: LiveView).
])

# Estrutura de cada registro (tupla Erlang):
# { node_id, status, event_count, last_payload, last_seen_at }
# Exemplo:
# { 42, :critical, 1_500, %{"temp" => 98.6, "vibration" => 0.9}, ~U[2026-03-25 10:00:00Z] }
```

**Por que `:set` e não `:ordered_set`:**
- `:set` usa hash table → O(1) para `lookup`, `insert`, `update_counter`.
- `:ordered_set` usa árvore balanceada → O(log n). Seria necessário apenas se precisássemos
  de ordenação por chave, o que não é o caso aqui.

**`read_concurrency: true`:** Cada conexão de LiveView que renderiza o dashboard faz um
`ets:lookup/2`. Esta flag instrui o BEAM a usar uma RW-Lock otimizada para múltiplos
leitores simultâneos, reduzindo contenção.

---

## 5. Estratégia de UPSERT (Write-Behind Worker)

O Worker que sincroniza ETS → SQLite usará o padrão **Ecto `on_conflict`**:

```elixir
# Em Ecto (Elixir), o UPSERT se parece com:
Repo.insert_all(NodeMetric, batch_of_records,
  on_conflict: {:replace, [:status, :total_events_processed, :last_payload, :last_seen_at, :updated_at]},
  conflict_target: :node_id
)
```

Isso se traduz para o SQL:
```sql
INSERT INTO node_metrics (node_id, status, total_events_processed, last_payload, last_seen_at, ...)
VALUES (?, ?, ?, ?, ?, ...)
ON CONFLICT(node_id) DO UPDATE SET
  status                 = excluded.status,
  total_events_processed = excluded.total_events_processed,
  last_payload           = excluded.last_payload,
  last_seen_at           = excluded.last_seen_at,
  updated_at             = excluded.updated_at;
```

**Idempotência garantida:** Se o Worker rodar duas vezes com o mesmo estado (ex: após
uma falha de rede que causou retry), o resultado no banco será idêntico. Não há duplicação.

---

## 6. Configuração de Performance do SQLite (PRAGMAs)

O SQLite precisa ser configurado para alta taxa de escritas. Isso é feito via PRAGMAs
que definem o comportamento do motor de armazenamento.

```elixir
# Em config/config.exs, na configuração do Ecto Repo:
config :w_core, WCore.Repo,
  database: "priv/w_core_prod.db",
  journal_mode: :wal,          # ← Mais importante
  cache_size: -64_000,         # 64 MB de cache de páginas em memória
  temp_store: :memory,
  synchronous: :normal
```

| PRAGMA | Valor | Por quê |
|---|---|---|
| `journal_mode` | `WAL` (Write-Ahead Log) | Permite leituras concorrentes enquanto o Worker grava. No modo padrão (`DELETE`), uma escrita bloqueia todas as leituras. |
| `synchronous` | `NORMAL` | O SQLite garante durabilidade em falhas de OS, mas não de hardware. Aceita risco de perder o último batch em queda de energia (aceitável para este cenário edge). |
| `cache_size` | `-64000` (64 MB) | Reduz I/O de disco ao manter mais páginas em RAM. Valor negativo = kilobytes. |
| `temp_store` | `MEMORY` | Tabelas temporárias (usadas internamente em ORDER BY) ficam em RAM. |

**Por que WAL é a configuração mais crítica:**
Sem WAL, cada `ets:tab2list` → batch insert bloquearia o dashboard de ler os dados.
Com WAL, leitores acessam o "snapshot" anterior enquanto a escrita acontece em paralelo.

---

## 7. Diagrama do Fluxo de Dados

```
Sensor (Edge Device)
      │
      ▼ HTTP POST / WebSocket
┌─────────────────────┐
│   Phoenix Endpoint  │
└─────────┬───────────┘
          │ cast assíncrono (não bloqueia)
          ▼
┌─────────────────────┐      ┌──────────────────────────┐
│  TelemetryGenServer │─────►│  ETS: w_core_telemetry   │
│  (recebe heartbeat) │      │  cache                   │
└─────────────────────┘      │  {node_id, status,       │
                              │   event_count, payload,  │
          ┌───────────────────│   last_seen_at}          │
          │ PubSub broadcast  └──────────┬───────────────┘
          ▼                              │ flush a cada X seg
┌─────────────────────┐                 ▼
│  LiveView Dashboard │      ┌──────────────────────────┐
│  (lê do ETS)        │      │  FlushWorker (GenServer) │
└─────────────────────┘      │  Batch UPSERT            │
                              └──────────┬───────────────┘
                                         ▼
                              ┌──────────────────────────┐
                              │  SQLite (WAL mode)       │
                              │  → node_metrics          │
                              └──────────────────────────┘
```

---

## 8. Próximos Passos

1. **Passo 1 (Fundação):** Criar o projeto Phoenix, configurar SQLite via `ecto_sqlite3`,
   gerar as migrations deste draft.
2. **Passo 2 (OTP):** Implementar `TelemetryGenServer` e `FlushWorker` com supervisão.
3. Documentar em `/docs/drafts/step-1-foundation.md` após a implementação.
