# Draft 003 / Step 2: Motor OTP + ETS — Ingestor e Write-Behind Worker

**Status:** Implementado
**Data:** 2026-03-25
**Autor:** Adalberto
**Depende de:** Draft 001, Draft 002

---

## 1. O que foi implementado

Dois GenServers que formam o coração do sistema de ingestão:

| Módulo | Arquivo | Papel |
|---|---|---|
| `WCore.Telemetry.Cache` | `lib/w_core/telemetry/cache.ex` | Owner da tabela ETS. API de escrita de eventos. |
| `WCore.Telemetry.FlushWorker` | `lib/w_core/telemetry/flush_worker.ex` | Sincroniza ETS → SQLite a cada 5s via UPSERT em lote. |

---

## 2. Diagrama Arquitetural

```
Sensor (heartbeat)
      │
      ▼ (qualquer processo, sem bottleneck)
Cache.record_event/4
      │
      │  :ets.update_counter/4  ← atômico, O(1)
      │  :ets.update_element/3  ← atualiza estado
      ▼
┌─────────────────────────────────────┐
│  ETS :w_core_telemetry_cache        │
│  { machine_id, status, payload,     │  ← memória RAM, sem I/O de disco
│    timestamp, event_count }         │
└──────────────────┬──────────────────┘
                   │
                   │  :ets.tab2list/1  (a cada 5s)
                   ▼
          FlushWorker (GenServer)
                   │
                   │  Repo.insert_all + ON CONFLICT DO UPDATE
                   ▼
┌─────────────────────────────────────┐
│  SQLite (WAL mode)                  │
│  tabela node_metrics                │  ← fonte de verdade persistida
└─────────────────────────────────────┘
```

---

## 3. Decisões de Design e Trade-offs

### 3.1 Por que `record_event` escreve no ETS diretamente (sem `GenServer.cast`)

**O problema com `cast`:**
```
Sensor → GenServer.cast → [mailbox: msg1, msg2, msg3 ... msg10.000] → processa 1 a 1
```
Sob alta frequência, a mailbox do GenServer seria o novo gargalo. O processo
ficaria sobrecarregado e o sistema degradaria progressivamente.

**A solução:**
O GenServer `Cache` serve apenas como *owner* da tabela ETS. A função
`record_event/4` bypassa a mailbox e escreve direto na tabela usando as
primitivas atômicas do ETS. Qualquer processo na BEAM pode chamar
`record_event` de forma concorrente e segura.

### 3.2 Por que `:set` e não `:ordered_set` no ETS

| Tipo | Estrutura interna | Lookup | Quando usar |
|---|---|---|---|
| `:set` | Hash table | O(1) | Quando a chave é opaca e não precisamos de ordenação |
| `:ordered_set` | Árvore AVL | O(log n) | Quando iteração ordenada por chave é necessária |

Nossa chave é `machine_id` (string opaca). Não precisamos de ordenação.
`:set` com O(1) é a escolha correta.

### 3.3 `read_concurrency: true` — o que muda internamente

Sem a flag: o ETS usa um único RW-lock global por tabela.
```
LiveView-1 (lendo) ──┐
LiveView-2 (lendo) ──┤── [lock global] ← contenção
LiveView-3 (lendo) ──┘
```

Com `read_concurrency: true`: o BEAM usa locks por bucket de hash.
```
LiveView-1 (lendo bucket A) ──┐
LiveView-2 (lendo bucket B) ──┤── sem contenção entre leitores de buckets distintos
LiveView-3 (lendo bucket C) ──┘
```
Em um dashboard com N conexões LiveView simultâneas, isso reduz drasticamente
a contenção de leitura. O custo: escrita fica ligeiramente mais lenta
(precisa invalidar mais caches de CPU). Para nosso padrão de uso — muitas
leituras, poucas escritas no dashboard — o trade-off é favorável.

### 3.4 `update_counter` + `update_element`: garantia do contador

O contador de eventos precisa ser incrementado atomicamente para evitar
race conditions:

```
Processo A: lê count=5
Processo B: lê count=5
Processo A: escreve count=6  ← "A" perdeu o incremento de B
Processo B: escreve count=6  ← correto seria 7
```

`:ets.update_counter/4` é uma operação atômica no nível do BEAM. Não existe
uma "leitura e depois escrita" — é uma única instrução indivisível.

O `update_element` seguinte atualiza os outros campos e **não** é atômico em
relação ao counter. Sob concorrência extrema, dois processos podem interfoliar
suas chamadas `update_element`, fazendo com que o `status` refletido seja do
penúltimo evento. **O counter, contudo, será sempre correto.**

Para telemetria, este trade-off é aceitável: preferimos contadores precisos
com estado "mais recente aproximado" a contadores incorretos.

### 3.5 `send_after` vs `:timer.send_interval` no FlushWorker

```elixir
# :timer.send_interval → dispara a cada T ms, independente do tempo do flush
# Risco: se o flush demorar 4s e o intervalo for 5s, temos apenas 1s de folga.
# Com drift acumulado, flushes podem se sobrepor.

# Process.send_after → agenda o próximo flush APÓS o atual terminar.
# Garante um intervalo mínimo entre flushes — backpressure natural.
```

### 3.6 Incremento cumulativo do `total_events_processed`

Em vez de substituir o valor no UPSERT, usamos uma expressão SQL:

```sql
ON CONFLICT(node_id) DO UPDATE SET
  total_events_processed =
    node_metrics.total_events_processed + excluded.total_events_processed
```

Isso garante que cada ciclo de flush **acumula** os eventos ao total existente,
sem precisar de um SELECT anterior. Idempotência: se o mesmo lote for inserido
duas vezes (ex: falha após commit, retry), o total seria incrementado duas vezes
— este é o único ponto sem idempotência plena. Mitigação futura: usar um campo
de "última sequência processada".

---

## 4. Árvore de Supervisão

```
WCore.Supervisor (:one_for_one)
├── WCoreWeb.Telemetry
├── WCore.Repo
├── Ecto.Migrator
├── DNSCluster
├── Phoenix.PubSub
├── WCore.Telemetry.Cache       ← inicia primeiro (cria tabela ETS)
├── WCore.Telemetry.FlushWorker ← inicia depois (depende da tabela ETS e do Repo)
└── WCoreWeb.Endpoint
```

**Estratégia `:one_for_one`:** se o `FlushWorker` falhar, somente ele é
reiniciado. O `Cache` (e sua tabela ETS) permanecem intactos. Os eventos
continuam sendo acumulados durante o restart do worker — resiliência sem
perda de dados em memória.

---

## 5. Próximos Passos

- **Step 3:** Implementar o Dashboard LiveView que lê do ETS via `Cache.lookup/1`
  e reage via `Phoenix.PubSub` quando o FlushWorker detectar mudança de status.
- Adicionar broadcast de `PubSub` no `FlushWorker` ao detectar mudança de
  `status` entre o ciclo anterior e o atual.
