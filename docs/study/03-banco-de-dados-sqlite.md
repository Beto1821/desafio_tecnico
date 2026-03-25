# Estudo: Banco de Dados e SQLite

> Pontos de defesa para a entrevista técnica.

---

## Pergunta: "Por que o schema tem apenas duas tabelas de telemetria?"

Porque o requisito é **estado atual**, não histórico completo.

```
nodes        → "Quais sensores existem na Planta 42?"
node_metrics → "Qual é o estado atual de cada sensor?"
```

**`nodes`** é o cadastro estático. Muda raramente (quando um novo sensor é instalado).

**`node_metrics`** tem **1 linha por sensor** — a linha é sobrescrita via UPSERT.
Não é uma série temporal bruta; é um "snapshot" do último estado.

---

## Pergunta: "Por que não armazenar o histórico completo de eventos no SQLite?"

**Cálculo rápido:**
- 8 sensores × 1 evento/segundo × 86.400 segundos/dia = **691.200 linhas/dia**.
- Em 30 dias: ~20 milhões de linhas.

Com SQLite embutido em Edge, isso criaria:
1. Crescimento ilimitado do arquivo em disco.
2. Queries lentas no dashboard (sem particionamento).
3. O mesmo gargalo de I/O que derrubou o sistema legado.

**Nossa decisão:** o histórico vive no ETS enquanto a aplicação roda. O SQLite
guarda apenas o último estado para sobreviver a reinicializações. É uma escolha
deliberada, não uma limitação técnica.

**Se o requisito evoluir:** adicionar uma tabela `sensor_events` com retenção
limitada (ex: últimas 24h), limpeza via `DELETE WHERE recorded_at < NOW() - INTERVAL`.

---

## Pergunta: "O que é WAL mode no SQLite e por que ativamos?"

WAL = Write-Ahead Logging. É o modo de journaling que controla como o SQLite
registra mudanças antes de aplicá-las ao arquivo principal.

**Modo padrão (DELETE / Rollback Journal):**
```
Escrita em andamento → LOCK EXCLUSIVO → leitores bloqueados
```
Enquanto o FlushWorker insere o lote, o dashboard não consegue ler. Resultado:
painel "congelando" a cada 5 segundos.

**WAL mode:**
```
Escrita → arquivo WAL (separado)
Leitores → veem o snapshot anterior (arquivo principal) → sem bloqueio
```

Leitores e escritores operam em paralelo. O BEAM reconcilia o WAL com o arquivo
principal em background (checkpoint).

**Ativação via Ecto:**
```elixir
config :w_core, WCore.Repo,
  database: "priv/w_core_prod.db",
  journal_mode: :wal
```

---

## Pergunta: "O que é UPSERT e como garantimos idempotência no FlushWorker?"

UPSERT = INSERT + UPDATE combinados. "Insira; se já existir, atualize."

**SQL gerado:**
```sql
INSERT INTO node_metrics (node_id, status, last_payload, ...)
VALUES (42, 'warning', '{"temp": 601}', ...)
ON CONFLICT(node_id) DO UPDATE SET
  status      = excluded.status,
  last_payload = excluded.last_payload,
  total_events_processed =
    node_metrics.total_events_processed + excluded.total_events_processed;
```

**`excluded`** é uma tabela virtual do SQLite que representa os valores que
"tentaram ser inseridos" mas conflitaram. É a forma de referenciar o novo valor
dentro da cláusula UPDATE.

**Idempotência:** se o mesmo lote for inserido duas vezes (ex: retry após falha),
os campos de estado (`status`, `last_payload`) serão idempotentes — o resultado
é o mesmo. **Exceção:** `total_events_processed` será somado duas vezes. Este é
o único ponto não idempotente — documentado como trade-off consciente.

---

## Pergunta: "Por que há índices em `status` e `last_seen_at`?"

Índices são estruturas de dados (B-tree) que evitam full table scan.

**`idx_node_metrics_status`:**
```sql
SELECT * FROM node_metrics WHERE status = 'critical';
-- Sem índice: varre todas as linhas (O(n))
-- Com índice: salta direto para as linhas 'critical' (O(log n))
```
O dashboard filtra por status constantemente. Sem índice, cada carregamento
de página executaria um full scan.

**`idx_node_metrics_last_seen_at`:**
```sql
SELECT * FROM node_metrics WHERE last_seen_at < NOW() - INTERVAL '5 minutes';
-- Detecta sensores "mortos" (sem heartbeat recente)
```

**Por que NÃO criamos índice em `last_payload`:**
`last_payload` é um JSON blob — não é consultado diretamente com WHERE.
Indexar colunas não filtráveis desperdiça espaço e torna escritas mais lentas.

---

## Pergunta: "O que é o `conflict_target` no Ecto?"

É o campo (ou conjunto de campos) cujo conflito aciona o `ON CONFLICT DO UPDATE`.

```elixir
Repo.insert_all(NodeMetric, metrics,
  on_conflict: [set: [...]],
  conflict_target: :node_id   # ← "conflito em node_id dispara o UPDATE"
)
```

Sem `conflict_target`, o banco não sabe qual constraint foi violada e pode
ignorar o conflito silenciosamente ou lançar um erro.

A constraint `UNIQUE(node_id)` na migration é o que torna isso possível —
sem ela, não haveria conflito detectável.

---

## Pergunta: "Como funciona o seed idempotente?"

Estratégia `get_or_insert`: antes de inserir, verifica se o registro já existe.

```elixir
node =
  case Repo.get_by(Node, machine_identifier: machine_id) do
    nil      -> Repo.insert!(changeset)   # 1ª execução: insere
    existing -> existing                  # 2ª+: reutiliza
  end
```

**Por que não `insert_all` com `on_conflict: :nothing`:**
`:nothing` não retorna os IDs dos registros existentes. Precisaríamos de um
`get_by` após o insert de qualquer forma para obter o `node.id` e criar o
`node_metrics` associado. O padrão `get_or_insert` é mais explícito e legível.
