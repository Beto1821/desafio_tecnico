# Passo 5: Empacotamento para o Edge (Infraestrutura)

**Status:** Concluído
**Data:** 2026-03-26

## 1. Objetivo

Empacotar a aplicação como uma `mix release` otimizada dentro de um
container Docker mínimo, pronto para rodar no servidor local da Planta 42
(Edge Computing), garantindo persistência do banco SQLite entre reinícios.

---

## 2. Estratégia: Multi-Stage Build

O `Dockerfile` usa dois estágios para minimizar a imagem final:

```
Estágio 1 (builder)          Estágio 2 (runner)
─────────────────────         ─────────────────────
hexpm/elixir:1.19.5           debian:trixie-slim
  + Erlang/OTP 28             + ERTS embutido (~50 MB)
  + Mix / Hex                 + binário compilado
  + compilador                + SEM código-fonte
  + assets (Tailwind)         + SEM Mix ou Hex
  ≈ 800 MB                    ≈ 100 MB total
```

O artefato da release já carrega o ERTS (Erlang Runtime) embutido —
não é necessário instalar Erlang no servidor de produção.

---

## 3. Diagrama Arquitetural — Fluxo Final

```
┌─────────────────────────────────────────────────────────────────┐
│                     Docker Container (w_core)                   │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                  BEAM / OTP Supervisor                   │   │
│  │                                                          │   │
│  │  ┌─────────────┐   write    ┌─────────────────────────┐ │   │
│  │  │  Simulator  │──────────▶│   Cache (ETS :public)   │ │   │
│  │  │  (8 procs)  │           │  :w_core_telemetry_cache │ │   │
│  │  └─────────────┘           └────────────┬────────────┘ │   │
│  │                                         │ tab2list/1   │   │
│  │  ┌──────────────────────────────────────▼────────────┐ │   │
│  │  │            FlushWorker (a cada 5s)                 │ │   │
│  │  │         UPSERT em lote → SQLite (WAL mode)        │ │   │
│  │  └──────────────────────────────────────────────────┘ │   │
│  │                                                          │   │
│  │  ┌──────────────────────────────────────────────────┐   │   │
│  │  │    LiveView Dashboard (/telemetry)               │   │   │
│  │  │    poll ETS 1×/s → diff WebSocket → browser     │   │   │
│  │  └──────────────────────────────────────────────────┘   │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              │ read/write                       │
│                  ┌───────────▼────────────┐                     │
│                  │  SQLite (WAL mode)     │                     │
│                  │  w_core_prod.db        │                     │
│                  └───────────────────────┘                     │
│                              │                                  │
└──────────────────────────────│──────────────────────────────────┘
                               │ volume mount
                    ┌──────────▼──────────┐
                    │   /data (host OS)   │
                    │  persistência entre │
                    │  reinícios          │
                    └─────────────────────┘
```

---

## 4. Persistência do SQLite no Edge

O ponto crítico de uma aplicação com SQLite em container é garantir que o
arquivo `.db` **não seja destruído** quando o container for substituído
(deploy, crash, atualização).

**Solução:** Volume externo montado no `DATABASE_PATH`:

```bash
docker run \
  -v /data/planta42:/data \
  -e DATABASE_PATH=/data/w_core_prod.db \
  -e SECRET_KEY_BASE=$(mix phx.gen.secret) \
  -e PHX_HOST=planta42.local \
  -p 4000:4000 \
  w_core:latest
```

O diretório `/data/planta42` no host sobrevive a qualquer operação no container.

---

## 5. Como Fazer o Build e Rodar

```bash
# Build da imagem
docker build -t w_core:latest .

# Primeira execução (roda migrações automaticamente via Ecto.Migrator)
docker run \
  -v /data/planta42:/data \
  -e DATABASE_PATH=/data/w_core_prod.db \
  -e SECRET_KEY_BASE=<gerado_com_mix_phx_gen_secret> \
  -e PHX_HOST=planta42.local \
  -p 4000:4000 \
  w_core:latest
```

---

## 6. Trade-offs Documentados

| Decisão | Alternativa | Por que escolhemos |
|---|---|---|
| SQLite local | PostgreSQL | Requisito do desafio; ideal para Edge (zero infra externa) |
| WAL mode | Journal padrão | Leituras simultâneas sem lock; crítico para telemetria |
| `mix release` | `mix run` | Binário self-contained, sem Mix/Hex no servidor |
| Multi-stage Docker | Single-stage | Imagem final ~8× menor; sem código-fonte exposto |
| Volume para `.db` | Bind mount simples | Portabilidade entre ambientes de edge |
