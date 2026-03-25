# 📖 Regras de Ouro e Guia de Engenharia - Desafio Web-Engenharia

Este documento serve como a "Bússola de Arquitetura" para o desenvolvimento do Simulador de Telemetria Industrial. Todas as interações com o Claude/Copilot devem seguir estas diretrizes.

---

## 🏗️ 1. Princípios de Design (Missão Crítica)
* **Performance:** Priorize o uso de Buffering e Batch Processing para persistência. Nunca grave no banco um registro por vez em alta frequência.
* **Resiliência:** O sistema deve lidar com falhas de rede e picos de dados (Backpressure).
* **Concorrência:** Use padrões nativos da linguagem (ex: Goroutines/Channels em Go) para evitar Race Conditions.
* **Idempotência:** Garanta que dados duplicados não corrompam o estado do sistema.

## 📝 2. Comunicação Técnica e Documentação
* **Draft-First:** Antes de cada grande mudança de código, devemos escrever ou atualizar um rascunho em `/docs/drafts/`.
* **Explicação de Trade-offs:** Para cada decisão (ex: escolher PostgreSQL vs InfluxDB), documente o *porquê* e o que estamos sacrificando.
* **Código Legado:** "Código bom que não pode ser explicado é código legado". O código deve ser autoexplicativo e bem comentado onde a lógica for complexa.

## 🌿 3. Fluxo de Trabalho e Git
* **Conventional Commits:** Siga rigorosamente:
    - `feat:` (novas funcionalidades)
    - `fix:` (correção de bugs)
    - `docs:` (documentação e rascunhos)
    - `refactor:` (melhoria de código sem mudar lógica)
    - `perf:` (melhorias de desempenho)
* **Branching:** Nunca trabalhar na `main`. Sempre criar `feature/nome-da-feature`.
* **PR Descriptions:** Cada Pull Request deve ter um resumo técnico do que foi resolvido.

## 💻 4. Padrões de Código
* **SOLID & Clean Code:** Funções pequenas, responsabilidade única e baixo acoplamento.
* **Logs Estruturados:** Use logs em formato JSON ou estruturados para facilitar a observabilidade.
* **Testes:** Implementar testes unitários para a lógica de negócio central (especialmente para o processamento de dados).

---

## 🤖 Instrução para a IA (System Prompt)
"Sempre que eu solicitar um código ou sugestão, valide se ela fere algum dos princípios acima. Se houver um trade-off de performance ou complexidade, aponte-o antes de implementar."