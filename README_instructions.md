# Desafio Técnico Elite: Motor de Estado em Tempo Real (W-Core)

Bem-vindo ao desafio técnico para Engenharia de Software na **Web-Engenharia**. 

Nós construímos sistemas de missão crítica, arquiteturas cognitivas SOTA e infraestruturas resilientes puramente na BEAM. Este teste foi desenhado para avaliar não apenas sua capacidade de escrever código, mas como você toma decisões arquiteturais, gerencia estado concorrente e justifica suas escolhas.

---

## O Briefing: O Incidente na Planta 42

**Contexto da Missão:**
A Web-Engenharia foi acionada em caráter de urgência por um de seus clientes industriais. A "Planta 42", um complexo de manufatura operando 24/7, está à beira de um apagão logístico. Eles possuem milhares de sensores (Edge Devices) monitorando a saúde do maquinário.

**O Problema:**
O sistema legado deles — um monólito engessado — não está aguentando a carga. Os sensores enviam um "pulso" (heartbeat) a cada poucos segundos contendo métricas vitais. O banco de dados relacional tradicional sofre *lock* constante de escrita, os painéis da sala de operações apresentam um atraso de minutos (inaceitável para missão crítica), e falsos positivos estão paralisando a produção.

**A Sua Missão:**
Você foi alocado na "Força-Tarefa W-Core". Sua missão é substituir o gargalo construindo um motor de estado em tempo real. O sistema rodará localmente no servidor da planta (Edge Computing), usando um banco de dados embutido, e deve ser imune a picos de tráfego. 

A diretriz da operação é clara: *"Não podemos perder eventos, a tela deve piscar em tempo real na falha de uma máquina, e o histórico deve estar a salvo caso o servidor reinicie."*

---

## Stack e Restrições

* **Linguagem & Framework:** Elixir + Phoenix LiveView.
* **Banco de Dados:** SQLite local (estritamente proibido o uso de dependências externas como Postgres ou Redis).
* **Autenticação:** Gerada exclusivamente via `phx.gen.auth`.
* **Estado & Cache:** Uso obrigatório de ETS e processos OTP (GenServer/Supervisor) para o fluxo de dados.
* **Design System:** Componentes HEEx puros, criados por você (nada de bibliotecas pesadas de UI de terceiros).
* **Infraestrutura:** Uma release Elixir pura, rodando sobre um Dockerfile simples.

---

## A Regra de Ouro: A Cultura da Documentação

Para nós, código que funciona mas não pode ser explicado é código legado. 
**A cada passo de evolução concluído, você deve criar um arquivo Markdown na pasta `/docs/drafts/`** (ex: `/docs/drafts/step-1-foundation.md`). 

Cada rascunho deve conter:
1. O que foi implementado.
2. O que mudou na arquitetura (diagramas em texto ou Mermaid são bem-vindos).
3. Os *trade-offs* e o porquê das decisões (especialmente envolvendo concorrência e o banco).

---

## Blueprint de Dados (Modelagem)

A arquitetura exige a divisão do estado em duas camadas para evitar o gargalo de I/O:

### 1. Camada de Persistência (SQLite / Ecto)
O banco atua como a fonte de verdade de longo prazo.

* **Contexto `Accounts`:** Tabela `users` (Operadores da Planta 42, gerado pelo phx.gen.auth).
* **Contexto `Telemetry`:** * Tabela `nodes` (Cadastro estático dos sensores: `id`, `machine_identifier`, `location`).
  * Tabela `node_metrics` (Consolidado com o último estado conhecido: `node_id`, `status`, `total_events_processed`, `last_payload`, `last_seen_at`).

### 2. Camada Transacional em Memória (Erlang ETS)
Onde o "tsunami" de eventos é absorvido em tempo real.

* **Tabela ETS:** `:w_core_telemetry_cache`
* **Estrutura sugerida:** `{node_id, status, event_count, last_payload, timestamp}`

*O Desafio Arquitetural:* Eventos chegam -> GenServer atualiza o ETS imediatamente -> Um Worker assíncrono varre o ETS a cada `X` segundos/eventos e faz um `upsert` em lote no SQLite (*Write-Behind*).

---

## Etapas de Evolução do Projeto

### Passo 1: O Perímetro de Segurança (Fundação e Autenticação)
* **Missão:** Iniciar a aplicação, configurar o SQLite, gerar a autenticação e desenhar os limites do domínio (`Telemetry`) isolado do web.
* **Entregável:** `/docs/drafts/step-1-foundation.md`

### Passo 2: O Coração da Usina (Erlang OTP & ETS)
* **Missão:** Construir o sistema de ingestão. Usar `GenServer` para receber o tráfego, gravar no ETS para performance extrema e implementar o mecanismo *Write-Behind* para o SQLite.
* **Entregável:** `/docs/drafts/step-2-otp-ets.md` (Defenda o tipo de tabela ETS e a estratégia de supervisão).

### Passo 3: A Sala de Controle (Design System e LiveView)
* **Missão:** Criar o Dashboard para usuários autenticados usando LiveView e componentes HEEx limpos. A interface deve ler os dados quentes do ETS e reagir instantaneamente via `Phoenix.PubSub` quando novos pulsos alterarem o status das máquinas.
* **Entregável:** `/docs/drafts/step-3-liveview-ds.md` (Explique como evitou gargalos no PubSub).

### Passo 4: Simulação de Caos (Testes Rigorosos)
* **Missão:** Provar a resiliência. Além de testes unitários, crie um teste de integração que injete **10.000 eventos concorrentes**. Prove via asserções que o ETS não perdeu a conta, que não houve condição de corrida e que o SQLite sincronizou o estado corretamente.
* **Entregável:** `/docs/drafts/step-4-tests.md`

### Passo 5: O Empacotamento para o Edge (Infraestrutura)
* **Missão:** Criar o `Dockerfile` gerando uma `mix release` otimizada, garantindo a persistência do volume do banco. 
* **Entregável:** `/docs/drafts/step-5-infra-arch.md` (Inclua um diagrama arquitetural documentando o fluxo final).

---

## O que vamos avaliar?

1. **Maturidade OTP:** O uso correto de GenServers, Supervisors e controle de concorrência.
2. **Domínio do ETS:** Compreensão de performance no Erlang (ex: `ets:update_counter`).
3. **Qualidade da Comunicação:** Seus rascunhos revelam clareza técnica.
4. **Separação de Preocupações (CQRS base):** A divisão clara entre o fluxo de escrita orientado a eventos e o fluxo de leitura reativo.

**Boa sorte. Estamos ansiosos para ver sua engenharia em ação.**
