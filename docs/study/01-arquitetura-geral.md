# Estudo: Arquitetura Geral do W-Core

> Pontos de defesa para a entrevista técnica.

---

## Pergunta: "Me explique a arquitetura do sistema."

O sistema é dividido em **duas camadas de estado** com responsabilidades distintas:

```
Sensor → [Camada Quente: ETS] → [Camada Fria: SQLite]
              (RAM)                  (Disco)
```

**Camada Quente (ETS):**
- Absorve o tsunami de eventos em tempo real.
- Operações O(1), sem I/O de disco, sem locks de banco.
- Dados voláteis: se o servidor reiniciar, o ETS é perdido.

**Camada Fria (SQLite):**
- Fonte de verdade persistida. Sobrevive a reinicializações.
- Atualizada de forma assíncrona a cada ciclo do FlushWorker.
- Armazena apenas o **último estado** de cada sensor, não o histórico bruto.

---

## Pergunta: "Por que não gravar cada evento direto no banco?"

O sistema legado da Planta 42 colapsou exatamente por isso.

```
Sistema legado:  1.000 eventos/s  →  1.000 INSERTs/s  →  lock de escrita  →  colapso
W-Core:          1.000 eventos/s  →  ETS (RAM)  →  1 UPSERT/lote a cada 5s
```

Cada INSERT individual tem overhead de:
1. Serialização da query.
2. Aquisição de lock de escrita no arquivo SQLite.
3. Escrita no WAL (Write-Ahead Log).
4. Confirmação de durabilidade (fsync).

Com batching, esse overhead é pago **uma única vez** para N eventos.

---

## Pergunta: "O que é o padrão Write-Behind?"

É uma estratégia de cache onde:
1. Escritas vão primeiro para um cache rápido (ETS).
2. Um worker assíncrono persiste o cache no banco em intervalos regulares.

**Diferença do Write-Through:**
- Write-Through: escreve no cache E no banco ao mesmo tempo (consistência forte, mas lento).
- Write-Behind: escreve no cache, persiste depois (performance alta, janela de perda de dados).

**Nossa tolerância a perda:** se o servidor cair entre dois flushes, perdemos até 5 segundos de eventos. Para monitoramento industrial, isso é aceitável — o requisito era "não perder eventos em operação normal", não "tolerância zero a falhas de hardware".

---

## Pergunta: "Por que escolheram SQLite em vez de PostgreSQL ou InfluxDB?"

**Requisito do desafio:** rodar localmente no servidor da planta (Edge Computing), sem dependências externas.

**Trade-offs explícitos:**

| Critério | SQLite | PostgreSQL | InfluxDB |
|---|---|---|---|
| Instalação | Zero (embutido) | Servidor separado | Servidor separado |
| Escrita time-series | Limitado | Bom | Excelente |
| Consultas relacionais | Bom | Excelente | Ruim |
| Adequação ao Edge | Perfeito | Exagerado | Exagerado |

Para o cenário da Planta 42 (edge, sem equipe de infra, banco embutido), SQLite com WAL mode é a escolha correta. Sacrificamos escritas ultra-escaláveis em troca de zero dependências operacionais.

---

## Pergunta: "O que acontece se o FlushWorker travar ou reiniciar?"

O Supervisor usa a estratégia `:one_for_one`: apenas o processo falho é reiniciado.

- O `Cache` (ETS) continua rodando — nenhum evento é perdido da memória.
- Os sensores continuam escrevendo no ETS normalmente.
- O FlushWorker reinicia, recarrega o mapa `machine_id → node_id` do banco, e retoma os flushes.

**Janela de inconsistência:** durante o restart do FlushWorker, o SQLite pode ficar desatualizado por mais de 5 segundos. O ETS continua sendo a fonte de verdade para o dashboard nesse período.
