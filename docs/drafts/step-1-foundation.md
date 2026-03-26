# Passo 1: Fundação do Projeto e Banco de Dados

**Status:** Concluído
**Data:** 2026-03-26

## 1. Objetivo
Estabelecer a base do projeto Phoenix e configurar o banco de dados SQLite para suportar alta concorrência de escritas, preparando o terreno para a ingestão de telemetria.

## 2. Decisões Técnicas e Arquitetura

### 2.1. Framework e Stack
- **Phoenix 1.7+ & LiveView:** Escolhidos pela produtividade e capacidade nativa de lidar com atualizações em tempo real via WebSockets, sem necessidade de SPAs complexas (React/Vue).
- **SQLite3:** Conforme requisito do desafio. Excelente para sistemas embarcados e ambientes locais.

### 2.2. O Desafio de Performance (WAL Mode)
O comportamento padrão do SQLite bloqueia leituras durante operações de escrita. Em um cenário de telemetria de alta frequência, isso causaria travamentos no dashboard e lentidão na ingestão.
- **Solução:** O módulo `WCore.Repo` foi customizado no `init/2` para forçar `journal_mode: :wal` (Write-Ahead Logging) e `temp_store: :memory`. Isso permite leituras e escritas simultâneas, resolvendo o gargalo nativo do SQLite.

### 2.3. Modelagem de Dados (Ecto Schemas)
Criamos duas tabelas estruturadas para suportar UPSERTS dinâmicos:
1. `nodes` (Sensores físicos - Dados estáticos como `machine_identifier` e `location`).
2. `node_metrics` (Estado atual do sensor - Relacionamento 1:1). Utiliza o tipo `:map` (JSON) para o campo `last_payload`, permitindo flexibilidade se diferentes máquinas enviarem estruturas de dados distintas.

## 3. Próximos Passos
Com a fundação sólida e o banco não-bloqueante pronto, avançaremos para o motor de ingestão em memória (ETS) no Passo 2.
