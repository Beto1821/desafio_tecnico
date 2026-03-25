# Estudo: OTP, GenServer e Árvore de Supervisão

> Pontos de defesa para a entrevista técnica.

---

## Pergunta: "O que é OTP e por que ele importa aqui?"

OTP (Open Telecom Platform) é o framework de concorrência e resiliência do
Erlang/Elixir. É composto por behaviours (contratos de processo) como:
- `GenServer`: processo com estado gerenciado.
- `Supervisor`: processo que monitora outros e os reinicia em falha.
- `Application`: ponto de entrada que define a árvore de supervisão.

**Por que importa no W-Core:**
Todo o motor de telemetria — Cache e FlushWorker — é construído como processos
OTP supervisionados. Isso significa que falhas são isoladas, tratadas
automaticamente e não derrubam o sistema inteiro.

"Let it crash" não é descuido — é uma estratégia. Em vez de defender cada
linha de código contra todos os erros possíveis, deixamos o processo falhar
e o Supervisor cuida da recuperação.

---

## Pergunta: "Por que o `Cache` é um GenServer se ele não processa mensagens?"

Um GenServer é necessário por uma razão técnica fundamental: **ownership de ETS**.

No BEAM, toda tabela ETS pertence ao processo que a criou. Se esse processo
morrer, a tabela é destruída automaticamente.

```
Sem GenServer owner:
  Processo X cria ETS → Processo X falha → tabela destruída → sistema perde todos os dados

Com GenServer owner (supervisionado):
  Cache cria ETS → Cache falha → Supervisor reinicia Cache → Cache recria ETS
  (os dados do ETS são perdidos no restart, mas o sistema continua funcionando)
```

A alternativa seria criar o ETS como `:protected` ou transferir ownership —
mas ter um processo supervisionado dedicado é o padrão idiomático em Elixir.

---

## Pergunta: "Qual a diferença entre `call`, `cast` e `info` em GenServer?"

| Função | Tipo | Resposta | Uso |
|---|---|---|---|
| `GenServer.call/2` | Síncrono | Aguarda resposta | Quando o chamador precisa do resultado |
| `GenServer.cast/2` | Assíncrono | Fire-and-forget | Quando não precisamos de resposta |
| `handle_info/2` | Mensagem direta | — | `Process.send_after`, mensagens do sistema |

**No W-Core:**
- `FlushWorker` usa `handle_info(:flush, state)` — acionado por `Process.send_after`.
  Não usamos `call` nem `cast` para o timer, pois é o próprio processo enviando
  mensagem para si mesmo.
- `Cache.record_event` não usa nenhum dos três — escreve direto no ETS, bypassa
  completamente o GenServer.

---

## Pergunta: "Por que a ordem na árvore de supervisão importa?"

```elixir
children = [
  WCore.Repo,           # 1. Banco deve estar pronto
  WCore.Telemetry.Cache,        # 2. ETS deve existir antes do FlushWorker
  WCore.Telemetry.FlushWorker,  # 3. Depende do ETS (Cache) e do Repo
  WCoreWeb.Endpoint             # 4. Web só sobe quando tudo está pronto
]
```

Com estratégia `:one_for_one`, cada processo sobe na ordem da lista.
Se `FlushWorker` tentasse subir antes do `Cache`, a chamada `Cache.table()`
retornaria um átomo para uma tabela inexistente → `ArgumentError` no primeiro flush.

**Estratégias de supervisão:**
- `:one_for_one`: reinicia apenas o processo falho. ← usamos aqui.
- `:one_for_all`: reinicia todos se qualquer um falhar.
- `:rest_for_one`: reinicia o processo falho e todos que vieram depois dele na lista.

`:one_for_one` é a escolha certa porque Cache e FlushWorker têm falhas
independentes — não queremos reiniciar o ETS quando o FlushWorker falha.

---

## Pergunta: "Por que `send_after` em vez de `:timer.send_interval`?"

```elixir
# send_interval: dispara a cada T ms, independente do tempo de execução
:timer.send_interval(5_000, self(), :flush)
# Risco: se flush demorar 4.9s e o intervalo é 5s, temos 0.1s de folga.
# Com drift acumulado ao longo do tempo, flushes podem se sobrepor.

# send_after: agenda o próximo flush APÓS o atual terminar
defp schedule_flush do
  Process.send_after(self(), :flush, 5_000)
end
# No handle_info(:flush, state): executa flush → ao final, chama schedule_flush
# Garante mínimo de 5s entre flushes, independente de quanto o flush demorou.
```

**Analogia:** `send_interval` é como um alarme que toca a cada hora exata.
`send_after` é como dizer "dorme 1 hora depois que terminar a tarefa". O
segundo garante que você nunca acorda antes de terminar.

---

## Pergunta: "Como o GenServer mantém estado entre chamadas?"

O estado do GenServer é o segundo elemento da tupla retornada pelos callbacks:

```elixir
def init(_opts) do
  {:ok, %{node_id_map: load_node_id_map()}}  # ← estado inicial
end

def handle_info(:flush, state) do
  new_state = do_flush(state)   # ← recebe estado atual, retorna novo estado
  {:noreply, new_state}         # ← novo estado é preservado até o próximo callback
end
```

O `node_id_map` no estado do FlushWorker é o mapeamento `machine_id → node_id`
carregado do banco. Ao invés de fazer uma query a cada flush, reutilizamos o mapa
em memória e só recarregamos quando detectamos um `machine_id` desconhecido.

**Custo de manter estado no GenServer vs ETS:**
- Estado do GenServer: privado ao processo, acesso apenas via mensagens.
- ETS: compartilhado, acesso direto por qualquer processo.

O `node_id_map` fica no GenServer state (privado) porque só o FlushWorker precisa
dele. O cache de telemetria fica no ETS porque múltiplos processos (LiveView,
FlushWorker) precisam acessar.
