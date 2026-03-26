# Roteiro de Apresentação e Perguntas Difíceis

> Use este arquivo para preparar a demonstração ao vivo e se defender
> de perguntas avançadas da banca.

---

## 🎬 Roteiro da Demo ao Vivo (10–15 minutos)

### Ato 1 — Contexto (1 min)
> "O sistema legado da Planta 42 colapsava porque tentava gravar cada evento
> diretamente no banco. Construímos uma arquitetura de duas camadas para
> separar a velocidade de ingestão da velocidade de persistência."

Abra o terminal e mostre a árvore de supervisão iniciando:
```bash
iex -S mix phx.server
```
Aponte os logs:
- `FlushWorker iniciado. 8 node(s) no mapa.`
- `[Simulator] Iniciando simulação para 8 máquinas`
- `[Simulator] Sensor iniciado — machine=BOILER-01 pid=#PID<0.346.0>`

> "8 processos BEAM independentes, cada um emulando uma máquina real."

---

### Ato 2 — O Fluxo de Dados ao Vivo (3 min)

No `iex`, execute:

```elixir
# Mostre o estado quente do ETS — sem passar pelo banco
:ets.tab2list(:w_core_telemetry_cache)
```

> "Estes dados estão na RAM. Nenhuma query SQL foi executada agora."

Execute novamente após 2 segundos — mostre os contadores crescendo.

```elixir
# Agora compare com o banco
WCore.Repo.all(WCore.Telemetry.NodeMetric)
```

> "O `total_events_processed` no banco é menor — o FlushWorker ainda não
> sincronizou este ciclo. O banco está atualizado a cada 5 segundos,
> mas o ETS é atualizado em tempo real."

---

### Ato 3 — Dashboard em Tempo Real (3 min)

Acesse `http://localhost:4000/telemetry` sem estar logado.
- Mostre o redirect para `/users/log-in`.

> "A rota é protegida por `live_session` com `on_mount`. Plugs de Conn
> não protegem WebSockets — precisamos do callback no momento do mount."

Faça login com o operador criado. Mostre o dashboard.

Abra DevTools → Network → WS:
> "Cada mensagem aqui é apenas o diff do DOM — os números que mudaram.
> O LiveView não reenvia o card inteiro, só os bytes alterados."

Aguarde um sensor entrar em `critical` (temperatura ≥ 100°C):
> "O card pisca via `animate-pulse`. O operador percebe imediatamente
> sem precisar ler os números."

---

### Ato 4 — Prova de Concorrência (2 min)

```bash
mix test test/w_core/telemetry/chaos_test.exs --trace
```

> "10.000 processos BEAM simultâneos apontando para a mesma chave ETS.
> O counter chegou a exatamente 10.000. Zero eventos perdidos.
> Isso só é possível porque `:ets.update_counter/4` é uma operação
> atômica no nível do runtime Erlang."

---

### Ato 5 — Infraestrutura (1 min)

Mostre o `Dockerfile`:
> "Multi-stage build: imagem de build com ~800MB, imagem final com ~100MB.
> A `mix release` embute o ERTS — o servidor da Planta 42 não precisa
> ter Erlang instalado."

Aponte o comentário sobre volume:
> "SQLite vive em volume externo. O container pode ser destruído e
> recriado — os dados sobrevivem."

---

## ⚡ Perguntas Difíceis — Como Responder

---

### "Se o servidor reiniciar, você perde os eventos do ETS. Como trata isso?"

**Resposta:**
> "É um trade-off consciente documentado. O ETS é volátil por design.
> Nossa tolerância de perda é de até 5 segundos — o intervalo do FlushWorker.
> Para uma planta industrial que opera 24/7, perder 5 segundos de leituras
> de sensores em um crash de servidor é aceitável. O estado persistido no
> SQLite sobrevive — na próxima inicialização, o Simulator retoma de onde
> parou.
>
> Se a tolerância fosse zero, usaríamos um WAL de aplicação: cada evento
> também seria appendado em um arquivo de log antes do ETS, com checkpoints
> periódicos."

---

### "Por que não usar GenStage ou Broadway para o pipeline de dados?"

**Resposta:**
> "GenStage e Broadway são soluções para pipelines complexos com múltiplos
> estágios, backpressure configurável e processamento de filas externas
> (Kafka, RabbitMQ). Nossa arquitetura é mais simples: um único produtor
> (ETS) e um único consumidor (FlushWorker).
>
> Adicionar GenStage aqui seria over-engineering — introduziríamos
> complexidade de buffers intermediários e demand protocols para um
> problema que o padrão Write-Behind já resolve de forma mais direta.
> A regra do YAGNI (You Aren't Gonna Need It) se aplica."

---

### "O `total_events_processed` no banco pode ser duplicado se o FlushWorker reiniciar no meio de um flush. Como resolve?"

**Resposta:**
> "Esse é o único ponto não-idempotente do sistema, e está documentado
> como trade-off consciente no `step-2-otp-ets.md`.
>
> O cenário: FlushWorker faz INSERT no banco, banco confirma, mas o processo
> falha antes de decrementar o contador no ETS. No próximo flush, o mesmo
> delta é somado novamente.
>
> Para resolver isso de forma robusta, precisaríamos de um número de
> sequência (LSN) em cada registro ETS — o FlushWorker gravaria até qual
> sequência persistiu, e no restart retomaria desse ponto. Isso requer
> uma mudança na estrutura da tupla ETS e na lógica do flush.
>
> Para o escopo atual do desafio, o trade-off é aceitável."

---

### "Por que não usar Phoenix Channels em vez de LiveView?"

**Resposta:**
> "Phoenix Channels é a camada de baixo nível — o WebSocket bruto com
> pub/sub. LiveView é construído sobre Channels e adiciona:
>
> 1. Renderização server-side com diff automático
> 2. Gerenciamento de estado no servidor
> 3. Integração com o ciclo de vida da aplicação
>
> Para um dashboard de visualização de dados onde o estado vive no
> servidor (ETS), LiveView é a abstração correta. Channels seriam mais
> adequados para comunicação bidirecional complexa — um chat, um jogo
> multiplayer, ou quando o cliente precisa enviar dados frequentemente
> ao servidor."

---

### "Como o sistema escala para 1.000 sensores em vez de 8?"

**Resposta:**
> "A arquitetura escala bem até um certo ponto:
>
> **ETS:** O(1) por operação independente do número de chaves.
> 1.000 sensores = 1.000 entradas na hash table. Sem degradação.
>
> **Simulator:** 1.000 processos BEAM leves. O scheduler da BEAM gerencia
> eficientemente até milhões de processos.
>
> **FlushWorker:** O gargalo. Um único processo fazendo UPSERT de 1.000
> registros a cada 5s. SQLite tem limite de ~1M inserts/s em batch —
> 1.000 a cada 5s é trivial.
>
> **LiveView:** O polling leria 1.000 chaves ETS por segundo. Cada lookup
> é O(1), então 1.000 lookups ainda são sub-milissegundo.
>
> **Limite real:** o FlushWorker sendo um único processo. Para 100.000
> sensores, particionaríamos os FlushWorkers por faixa de `node_id`."

---

### "Por que `NaiveDateTime` em vez de `DateTime` no timestamp?"

**Resposta:**
> "O schema Ecto usa `:naive_datetime` porque o SQLite não tem tipo nativo
> de timezone. `NaiveDateTime` representa um ponto no tempo sem offset —
> assumimos que todos os sensores da Planta 42 operam no mesmo fuso horário
> do servidor.
>
> Se os sensores estivessem distribuídos em múltiplos fusos, usaríamos
> `DateTime` com UTC explícito. Para um sistema edge local em uma única
> planta, `NaiveDateTime` é a escolha correta e mais simples.
>
> Uma pegadinha: `NaiveDateTime.utc_now()` retorna microssegundos. O Ecto
> com SQLite espera precisão de segundos. Por isso usamos
> `NaiveDateTime.utc_now(:second)` no Simulator."

---

## 💡 Frases de Impacto para Usar na Entrevista

Use estas frases em momentos estratégicos:

> **Sobre ETS:**
> "Não é um cache de aplicação que gerenciamos — é uma tabela de hash
> mantida pela própria VM do Erlang, fora do heap de qualquer processo.
> Isso significa zero garbage collection overhead por operação."

> **Sobre Write-Behind:**
> "A ideia é simples: seja rápido para receber, seja eficiente para persistir.
> Separamos a velocidade de ingestão da latência de disco."

> **Sobre o teste de caos:**
> "10.000 processos, uma chave, zero perdas. Isso não é uma promessa de
> documentação — é uma asserção que o CI vai validar a cada commit."

> **Sobre a decisão de polling vs PubSub:**
> "A pergunta não é 'qual é mais moderno'. É 'qual resolve o problema sem
> criar novos problemas'. PubSub a cada evento criaria backpressure no
> cliente. Polling local no ETS cria backpressure natural — o cliente
> puxa quando está pronto."

> **Sobre o Dockerfile:**
> "A release embute o ERTS. O operador da Planta 42 não precisa saber o
> que é Erlang para rodar o sistema — é um binário como qualquer outro."

---

## 📋 Checklist Final Antes da Apresentação

- [ ] `iex -S mix phx.server` rodando sem erros
- [ ] Usuário cadastrado em `/users/register`
- [ ] Terminal com `iex` pronto para mostrar `:ets.tab2list`
- [ ] DevTools aberto em Network → WS
- [ ] `mix test test/w_core/telemetry/chaos_test.exs` passando
- [ ] Todos os drafts em `docs/drafts/` prontos para mostrar
- [ ] Conhecer os 5 commits principais do `git log --oneline`
