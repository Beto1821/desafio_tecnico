# Passo 4: Teste de Caos e Concorrência

**Status:** Concluído
**Data:** 2026-03-26

## 1. Objetivo

Provar matematicamente que o sistema de cache (ETS) é imune a Race Conditions
sob carga extrema. O teste injeta **10.000 eventos verdadeiramente concorrentes**
e verifica que nenhum incremento foi perdido.

---

## 2. O Problema: Race Condition em Contadores Compartilhados

O padrão clássico de incrementar um contador em memória compartilhada é
inerentemente inseguro quando dois ou mais processos operam simultaneamente:

```
# ❌ PADRÃO INSEGURO — leitura → modificação → escrita (três operações separadas)

Processo A lê:   count = 42
Processo B lê:   count = 42   ← B lê ANTES de A escrever
Processo A escreve: count = 43
Processo B escreve: count = 43  ← B sobrescreve com o mesmo valor!

Resultado: 2 eventos processados, contador marcou apenas +1. Evento perdido.
```

Em alta frequência (8 sensores × 2 eventos/s = ~16 eventos/s), essa janela de
tempo entre "ler" e "escrever" se torna uma fonte constante de corrupção silenciosa.

---

## 3. A Solução: `:ets.update_counter/4` — Atomicidade Nativa do BEAM

O Erlang/OTP resolve este problema com uma primitiva atômica no nível do runtime:

```elixir
# ✅ PADRÃO SEGURO — operação única e indivisível
:ets.update_counter(table, key, {position, increment}, default_record)
```

**Por que é seguro:** `:ets.update_counter/4` executa o ciclo
leitura-incremento-escrita como uma **única operação atômica** no nível do
scheduler da BEAM. É o equivalente a um `FETCH_ADD` atômico de hardware —
não existe janela de tempo entre ler e escrever, portanto não existe
oportunidade para race condition.

---

## 4. Estratégia do Teste de Caos

### 4.1. Arquivo
`test/w_core/telemetry/chaos_test.exs`

### 4.2. Mecanismo

O teste spawna **10.000 processos BEAM simultâneos** usando `Task.async/1`,
cada um chamando `Cache.record_event/4` para o mesmo `machine_id`:

```elixir
tasks =
  for _ <- 1..10_000 do
    Task.async(fn ->
      Cache.record_event("CHAOS-01", "ok", %{"temperature" => 72.5}, timestamp)
    end)
  end

Task.await_many(tasks, 30_000)

{_id, _status, _payload, _ts, event_count} = Cache.lookup("CHAOS-01")
assert event_count == 10_000
```

`Task.async/1` foi escolhido sobre `Task.async_stream` porque spawna
todos os 10.000 processos **imediatamente e sem backpressure**, criando
a contenção máxima possível sobre a mesma chave ETS.

### 4.3. Isolamento de Estado

A tabela ETS é um recurso global nomeado. Para isolar o teste sem derrubar
o processo `Cache` (que já está rodando pela supervision tree da aplicação),
o `setup` remove apenas as chaves específicas do teste antes de cada execução:

```elixir
setup do
  :ets.delete(Cache.table(), "CHAOS-01")
  :ok
end
```

---

## 5. Resultados

```
WCore.Telemetry.ChaosTest
  ✅ 10.000 eventos concorrentes não perdem nenhuma contagem no ETS (95ms)
  ✅ contadores de múltiplas máquinas são independentes e precisos    (86ms)

2 tests, 0 failures
```

- **10.000 eventos** processados em ~95ms (~105.000 eventos/s de throughput teórico)
- **0 incrementos perdidos** — o contador chegou a exatamente 10.000
- **Isolamento confirmado** — 4 máquinas com 2.500 eventos cada, sem "vazamento" entre chaves

---

## 6. O que este resultado prova para a Planta 42

| Cenário | Sem atomicidade | Com `:ets.update_counter` |
|---|---|---|
| 10.000 eventos concorrentes | Contador < 10.000 (perdas silenciosas) | Contador = 10.000 ✅ |
| 8 sensores simultâneos | Contadores se corrompem mutuamente | Cada máquina tem sua contagem precisa ✅ |
| Reinicialização do FlushWorker | Dados duplicados no SQLite | UPSERT somativo impede duplicação ✅ |

A arquitetura ETS com `update_counter` é matematicamente correta para o
problema de ingestão de telemetria em alta frequência. Não há perda de evento
possível no caminho quente `Simulator → Cache.record_event → ETS`.
