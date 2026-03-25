# Draft 001: Visão Geral da Arquitetura e Estratégia de Dados

**Status:** Proposto  
**Data:** 2026-03-25  
**Autor:** Adalberto

## 1. Contexto e Problema
O desafio exige um sistema de telemetria industrial de alta frequência. O principal gargalo identificado é o conflito entre a **velocidade de geração de dados** (milissegundos) e a **latência de persistência** em banco de dados. Inserções individuais (`INSERT`) para cada leitura de sensor causariam exaustão de conexões e IOPS.

## 2. Decisão Arquitetural: Padrão Ingestor-Worker

Decidi seguir uma arquitetura desacoplada baseada em três pilares:

### A. Buffer de Memória (Batching)
Em vez de persistência síncrona, utilizaremos um buffer em memória. 
- **O quê:** Os dados dos sensores são acumulados em uma estrutura de dados thread-safe.
- **Por quê:** Permite transformar 1.000 operações de escrita individuais em 1 única operação de lote (Bulk Insert), reduzindo drasticamente o overhead do banco.

### B. Concorrência via Workers
Utilizaremos o modelo de concorrência nativo (ex: Goroutines/Channels) para processar a telemetria.
- **Vantagem:** O simulador não fica travado esperando o banco de dados responder. Se o banco oscilar, o buffer absorve o impacto (até certo limite).

### C. Estratégia de Persistência (Time-Series)
A escolha de modelagem focará em **Séries Temporais**.
- **Trade-off:** Priorizaremos a velocidade de escrita e a facilidade de agregação (ex: média de temperatura por hora) em detrimento de relações complexas entre tabelas.

## 3. Riscos e Mitigação (Backpressure)
**Risco:** Se o simulador gerar dados mais rápido do que conseguimos salvar por um longo período, a memória do sistema pode esgotar.
**Mitigação:** Implementaremos um limite no buffer. Se o limite for atingido, aplicaremos uma estratégia de "Drop Oldest" ou sinalizaremos um alerta de sistema sobrecarregado (Backpressure).

## 4. Próximos Passos
1. Definir o Schema do Banco de Dados focado em performance de série temporal.
2. Implementar o Protótipo do Simulador de Sensores com suporte a múltiplos tópicos.