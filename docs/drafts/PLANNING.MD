# 📋 Planejamento de Desenvolvimento: Simulador de Telemetria Industrial

Este documento detalha a estratégia de implementação, os requisitos técnicos e as decisões arquiteturais antecipadas para o desafio técnico da Web-Engenharia.

## 🎯 Objetivo
Construir um ecossistema de telemetria capaz de simular, processar e persistir dados de sensores industriais em alta frequência, garantindo resiliência e baixo acoplamento.

---

## 🏗️ Fase 1: Arquitetura e Design (Semana 1)
*O foco aqui é o "Blueprint" do sistema antes da codificação intensiva.*

- [ ] **Definição do Modelo de Dados:** Estruturar o JSON de telemetria (SensorID, Timestamp, Valor, Unidade, Status).
- [ ] **Escolha da Stack de Persistência:** Avaliar entre SQL (PostgreSQL com TimescaleDB) ou NoSQL (InfluxDB) para séries temporais.
- [ ] **Desenho do Fluxo de Dados:** - Producer (Simulador) -> Queue/Buffer -> Consumer (Ingestion Service) -> Database.
- [ ] **Documentação Inicial:** Criar o primeiro rascunho em `/docs/drafts/architecture_decisions.md`.

## ⚙️ Fase 2: O Motor de Simulação (Backend Core)
*Implementação da lógica de geração de dados e concorrência.*

- [ ] **Simulador de Sensores:** Criar geradores assíncronos que simulem múltiplos tipos de sensores (Temperatura, Vibração, Pressão).
- [ ] **Gerenciamento de Concorrência:** Implementar Workers/Goroutines para processar pacotes de dados sem bloquear a execução principal.
- [ ] **Sistema de Buffering:** Implementar um buffer em memória para evitar escritas excessivas no disco (Batching).
- [ ] **Tratamento de Erros:** Definir estratégia de *Retries* e *Dead Letter Queues* para dados corrompidos.

## 💾 Fase 3: Camada de Persistência e API
*Garantir que os dados sejam armazenados de forma eficiente e fiquem disponíveis.*

- [ ] **Otimização de Escrita:** Implementar *Bulk Inserts* (inserção em lote) para alta performance.
- [ ] **API de Consulta:** Desenvolver endpoints REST ou GraphQL para recuperar o estado atual dos sensores e históricos.
- [ ] **Health Checks:** Implementar monitoramento da saúde do banco de dados e do serviço de ingestão.

## 📊 Fase 4: Interface e Visualização (Opcional/Frontend)
*Transformar dados brutos em insights.*

- [ ] **Dashboard Real-time:** Implementar WebSockets para atualização da interface sem refresh.
- [ ] **Visualização de Séries Temporais:** Gráficos de linha para acompanhamento de tendências.
- [ ] **Alertas:** Lógica visual para sensores fora dos parâmetros normais (ex: temperatura > 80ºC).

---

## 🛡️ Decisões Críticas de Engenharia (Para Defesa Técnica)

Ao longo deste projeto, as seguintes métricas de qualidade serão priorizadas:

1.  **Backpressure:** Como o sistema se comporta se o simulador gerar mais dados do que o banco consegue salvar?
2.  **Idempotência:** Garantir que o reprocessamento de um dado não gere duplicidade no banco.
3.  **Observabilidade:** Implementação de Logs estruturados para facilitar o rastreio de falhas em produção.
4.  **Clean Code:** Aplicação de princípios SOLID para facilitar a manutenção e evitar o "código legado" citado no desafio.

---

## 📅 Cronograma Estimado
1. **Dia 1-2:** Arquitetura, Setup e Simulador Base.
2. **Dia 3-4:** Persistência, Otimização de Banco e Concorrência.
3. **Dia 5:** API, Frontend e Refatoração.
4. **Dia 6:** Revisão final da Documentação (Drafts) e Testes Unitários.