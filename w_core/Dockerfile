# ─────────────────────────────────────────────────────────────────────────────
# Planta 42 — W-Core Telemetry Engine
# Multi-stage Docker build para mix release otimizada.
#
# Estágio 1 (builder): compila assets e a release Elixir
# Estágio 2 (runner) : imagem mínima, só o binário compilado
#
# Por que multi-stage?
# A imagem de build contém o compilador Erlang/Elixir (~800 MB).
# A imagem final carrega apenas o runtime ERTS embutido pela release
# (~50 MB), sem Mix, sem Hex, sem código-fonte.
# ─────────────────────────────────────────────────────────────────────────────

ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=26.2.5.2
ARG DEBIAN_VERSION=bookworm-20260316-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# ── Estágio 1: Builder ────────────────────────────────────────────────────────
FROM ${BUILDER_IMAGE} AS builder

# Instala ferramentas de build do sistema
RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

# Configura Mix para ambiente de produção
RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV="prod"

# Copia manifests de dependências primeiro para aproveitar o cache de layers.
# Se mix.exs e mix.lock não mudarem, o `mix deps.get` não re-executa.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Copia configurações de compilação (não contém segredos — apenas deps)
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Compila a aplicação primeiro (gera phoenix-colocated em _build/)
COPY priv priv
COPY lib lib
RUN mix compile

# Compila assets (Tailwind + esbuild) — depende do phoenix-colocated gerado acima
COPY assets assets
RUN mix assets.deploy

# Copia configurações de runtime (podem referenciar env vars)
COPY config/runtime.exs config/

# Copia scripts de release
COPY rel rel
RUN mix release

# ── Estágio 2: Runner ─────────────────────────────────────────────────────────
FROM ${RUNNER_IMAGE}

# Instala apenas o runtime mínimo necessário
# openssl e libncurses5 são requisitos do ERTS embutido
RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Define locale para UTF-8 — necessário para strings Elixir
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

WORKDIR /app

# Cria usuário não-root e diretório de dados com permissão correta
RUN useradd --create-home app && mkdir -p /data && chown app:app /data

# Copia o artefato compilado e garante permissão de execução nos binários
COPY --from=builder --chown=app:app /app/_build/prod/rel/w_core ./
RUN chmod +x /app/bin/server /app/bin/w_core

USER app

# Variáveis de ambiente obrigatórias em produção:
# SECRET_KEY_BASE  — gerado com `mix phx.gen.secret`
# DATABASE_PATH    — caminho para o arquivo SQLite no volume persistente
# PHX_HOST         — hostname público da aplicação
ENV PHX_SERVER=true

# ─────────────────────────────────────────────────────────────────────────────
# ATENÇÃO — Persistência do SQLite (Edge Computing):
#
# O banco SQLite vive em um arquivo local. Em produção, monte um volume
# externo no path configurado em DATABASE_PATH para que os dados sobrevivam
# ao reinício ou substituição do container:
#
#   docker run -v /data/planta42:/data \
#              -e DATABASE_PATH=/data/w_core_prod.db \
#              -e SECRET_KEY_BASE=$(mix phx.gen.secret) \
#              -e PHX_HOST=planta42.local \
#              -p 4000:4000 \
#              w_core:latest
# ─────────────────────────────────────────────────────────────────────────────

EXPOSE 4000

CMD ["/app/bin/server"]
