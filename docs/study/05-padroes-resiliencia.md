# Estudo: Padrões de Resiliência em Sistemas Distribuídos

> Pontos de defesa para a entrevista técnica.

---

## Pergunta: "O que é Backpressure e como implementamos?"

Backpressure é o mecanismo que **impede que um produtor de dados sobrecarregue
um consumidor mais lento**.

**O problema sem backpressure:**
```
Sensores produzem 10.000 eventos/s
FlushWorker persiste 1.000 eventos/s
→ Buffer cresce 9.000 registros/s → memória esgota → crash do sistema
```

**Nossa implementação (implícita via ETS `:set`):**
O ETS com tipo `:set` tem comportamento de backpressure natural: se o mesmo
`machine_id` enviar 100 eventos antes do flush, apenas o **último** é mantido
(a chave é sobrescrita). Eventos mais antigos são descartados automaticamente.

**Trade-off:** para sensores com alta frequência, eventos intermediários são
perdidos. Mantemos apenas o estado mais recente. Para monitoramento de saúde
de maquinário, isso é aceitável — o que importa é o estado atual, não cada
leitura individual.

**Backpressure mais sofisticado (evolução futura):**
- Usar um buffer com tamanho máximo (ex: `:queue` com limite).
- Implementar estratégia "Drop Oldest" ao atingir o limite.
- Emitir métrica/alerta quando o buffer estiver acima de 80% da capacidade.

---

## Pergunta: "O que é Idempotência e onde ela aparece no projeto?"

Uma operação é idempotente quando **executá-la N vezes produz o mesmo resultado
que executá-la 1 vez**.

**Onde garantimos:**

1. **Seeds (`priv/repo/seeds.exs`):**
   Padrão `get_or_insert` — rodar 10 vezes gera o mesmo banco que rodar 1 vez.

2. **UPSERT no FlushWorker:**
   `INSERT ... ON CONFLICT DO UPDATE` — inserir o mesmo estado duas vezes
   produz o mesmo resultado final (exceto `total_events_processed`).

3. **Tabela ETS com `:set`:**
   Inserir o mesmo `machine_id` múltiplas vezes substitui o registro —
   nunca duplica dados.

**Onde NÃO é idempotente (trade-off documentado):**
`total_events_processed` usa soma acumulativa. Um retry do FlushWorker após
uma falha parcial somaria o mesmo delta duas vezes. Mitigação futura: usar
um "número de sequência" para detectar replays.

---

## Pergunta: "O que é Batching e qual o ganho real?"

Batching = agrupar múltiplas operações em uma única chamada.

**Sem batching (1 INSERT por evento):**
```
Custo por INSERT:
  1. parse da query SQL
  2. aquisição de lock de escrita
  3. escrita no WAL
  4. release do lock

1.000 eventos = 1.000 × (1+2+3+4) = 4.000 operações
```

**Com batching (1 INSERT para N registros):**
```
INSERT INTO node_metrics VALUES (1,...), (2,...), ..., (N,...)

1.000 eventos = 1 × (1+2+3+4) = 4 operações
              + N escritas de dados (inevitáveis)
```

**Ganho prático no SQLite:** inserções individuais em SQLite podem chegar a
~50.000 ops/segundo. Com batching, o mesmo SQLite pode inserir >1.000.000
registros por segundo em um único `INSERT` em lote.

---

## Pergunta: "O que é o padrão CQRS mencionado na avaliação?"

CQRS = Command Query Responsibility Segregation. Separa o fluxo de **escrita**
(comandos) do fluxo de **leitura** (queries).

**No W-Core (CQRS simplificado):**

```
Fluxo de ESCRITA (Command):
  Sensor → Cache.record_event → ETS → FlushWorker → SQLite

Fluxo de LEITURA (Query):
  LiveView → Cache.lookup → ETS (dado quente)
  LiveView → Repo.all    → SQLite (dado persistido)
```

Os dois fluxos são completamente independentes:
- Escritas nunca bloqueiam leituras.
- Leituras nunca bloqueiam escritas.
- O ETS é otimizado para o padrão de leitura do dashboard (`read_concurrency: true`).

**Por que isso importa na entrevista:**
A Web-Engenharia avalia explicitamente "separação clara entre fluxo de escrita
orientado a eventos e fluxo de leitura reativo". CQRS é a resposta técnica
para essa avaliação.

---

## Pergunta: "O que são Race Conditions e como evitamos?"

Uma race condition ocorre quando o resultado de uma operação depende da ordem
de execução de processos concorrentes — e essa ordem não está garantida.

**Exemplo no nosso contexto:**
```
Processo A (sensor TURBINE-01): lê status = "ok"
Processo B (sensor TURBINE-01): lê status = "ok"
Processo B: escreve status = "critical"
Processo A: escreve status = "ok"  ← sobrescreveu o estado correto!
```

**Como mitigamos:**

1. **Counter:** `:ets.update_counter/4` é atômico — sem race condition no contador.

2. **Status/Payload:** usamos `:ets.update_element/3` separadamente do counter.
   Há uma janela de race condition aqui — documentada como trade-off aceitável
   (o "último escritor" vence, que é o comportamento correto para "último estado").

3. **Flush:** o FlushWorker é um processo único — não há dois FlushWorkers
   concorrentes. O loop `send_after` garante que um ciclo termina antes do
   próximo começar.

**Regra geral para a entrevista:**
Race conditions são evitadas ao garantir que operações em estado compartilhado
sejam atômicas (ETS primitives) ou serializadas (processo único = GenServer).
