# Estudo: ETS e Concorrência no BEAM

> Pontos de defesa para a entrevista técnica.

---

## Pergunta: "O que é o ETS e por que ele é tão rápido?"

ETS (Erlang Term Storage) é uma tabela de hash em memória gerenciada pela
VM do BEAM, fora do heap dos processos.

**Por que é rápido:**
1. **Sem cópia de dados entre processos:** dados ficam em memória compartilhada.
   Processos acessam diretamente sem serialização/deserialização de mensagens.
2. **Sem garbage collection por operação:** o GC do BEAM opera por processo.
   O ETS não participa do ciclo de GC individual.
3. **Operações O(1) para `:set`:** hash table com lookup direto pela chave.

**Comparação com GenServer + estado interno:**
```
GenServer state:  evento → mensagem → mailbox → processa → retorna
                  (serializado, um por vez)

ETS:              evento → :ets.insert(tabela, dado)
                  (direto na memória compartilhada, concorrente)
```

---

## Pergunta: "Quais são os tipos de tabela ETS? Por que escolhemos `:set`?"

| Tipo | Estrutura | Lookup | Característica |
|---|---|---|---|
| `:set` | Hash table | O(1) | Chave única. Mesma chave substitui o valor. |
| `:ordered_set` | Árvore AVL | O(log n) | Chave única. Iteração em ordem de chave. |
| `:bag` | Hash table | O(1) | Permite múltiplos valores por chave. |
| `:duplicate_bag` | Hash table | O(1) | Permite tuplas idênticas duplicadas. |

**Por que `:set` para telemetria:**
- `machine_identifier` é nossa chave. Queremos **1 registro por sensor** (último estado).
- Não precisamos de ordenação por chave — o dashboard ordena por status/timestamp na query.
- O(1) é necessário: `record_event` é chamado milhares de vezes por segundo.

---

## Pergunta: "O que é `read_concurrency: true` e quando usar?"

Internamente, o ETS usa RW-locks (Reader-Writer locks) para garantir isolamento.

**Sem `read_concurrency: true`:**
```
[Lock Global da Tabela]
  Leitor 1 ──┐
  Leitor 2 ──┤── aguarda lock → serializado
  Leitor 3 ──┘
```

**Com `read_concurrency: true`:**
```
[Lock por Bucket de Hash]
  Leitor 1 (bucket A) ──── executa imediatamente
  Leitor 2 (bucket B) ──── executa imediatamente (bucket diferente, sem contenção)
  Leitor 3 (bucket A) ──── aguarda apenas o Leitor 1 (mesmo bucket)
```

**Quando usar:** quando o padrão de uso tem **muito mais leituras que escritas**.
No nosso caso: N conexões LiveView lendo o dashboard vs. sensores escrevendo eventos.

**Custo:** escritas ficam ligeiramente mais lentas (precisam invalidar mais caches de CPU).
Para nosso padrão de uso, o trade-off é favorável.

---

## Pergunta: "Como `update_counter` garante que não perdemos contagens?"

Este é o conceito de **operação atômica**.

**O problema sem atomicidade (race condition):**
```
Processo A:  lê event_count = 5
Processo B:  lê event_count = 5
Processo A:  escreve event_count = 6   ← incrementou 1
Processo B:  escreve event_count = 6   ← também incrementou 1, mas sobrescreveu A
Resultado: 6 (perdemos 1 incremento. Correto seria 7)
```

**Com `:ets.update_counter/4`:**
A operação "leia, some, escreva" é uma instrução indivisível no nível da VM.
Nenhum outro processo pode interromper no meio.

```elixir
# O 4º argumento é o "default" — inserido se a chave não existir.
# O 3º argumento {posição, incremento} é a operação atômica.
:ets.update_counter(@table, machine_id, {5, 1}, {machine_id, status, payload, ts, 0})
```

**Analogia para explicar:** é como um caixa eletrônico que trava a conta durante
a transação. Mesmo que dois saques aconteçam ao mesmo tempo, cada um vê o saldo
correto antes de debitar.

---

## Pergunta: "Há alguma race condition no nosso `record_event`?"

Sim — e é um trade-off consciente.

```elixir
def record_event(machine_id, status, payload, timestamp) do
  :ets.update_counter(...)   # ← atômico: counter sempre correto
  :ets.update_element(...)   # ← NÃO atômico em relação ao counter
end
```

Entre as duas chamadas, outro processo pode executar seu próprio `update_element`,
sobrescrevendo `status`/`payload`/`timestamp` com valores intermediários.

**O que pode acontecer:**
- Processo A e B chegam quase simultaneamente.
- Counter: incrementado corretamente para ambos (atomicamente).
- Status: o último `update_element` a executar "vence" — pode ser A ou B.

**Por que é aceitável:**
- O counter (para `total_events_processed`) é sempre preciso.
- O `status` reflete o evento mais recente que completou `update_element` — em
  alta frequência, isso é "recente o suficiente" para monitoramento industrial.
- Se precisássemos de consistência absoluta de status, encapsularíamos tudo em
  uma única operação — mas ETS não oferece transações multi-operação nativas.
