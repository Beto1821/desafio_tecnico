# Passo 3: Dashboard em Tempo Real (LiveView)

**Status:** Concluído
**Data:** 2026-03-26

## 1. Objetivo
Criar uma interface em tempo real, protegida por autenticação, que exiba o status de todo o maquinário da Planta 42 sem sobrecarregar o banco de dados ou a rede do cliente.

## 2. Autenticação e Segurança
O acesso ao dashboard (`/telemetry`) foi restrito. Utilizamos `phx.gen.auth` para gerar o sistema de contas.
Como rotas LiveView trafegam via WebSockets (e não HTTP padrão), protegemos a montagem da tela utilizando um `live_session` e o callback `on_mount: [{WCoreWeb.UserAuth, :require_authenticated_user}]`, garantindo que o handshake inicial valide o token do usuário.

## 3. A Estratégia de Reatividade: Polling no ETS vs PubSub

Inicialmente, consideramos o uso do `Phoenix.PubSub` para realizar `broadcast` a cada novo evento gerado pelo `Simulator`. No entanto, em um cenário de metralhadora de dados (milhares de eventos por minuto), isso geraria:
1. Uma inundação de mensagens WebSocket para os clientes.
2. Sobrecarga inútil de renderização no DOM do navegador.

### A Solução: "Pull" via Timer
Optamos por uma abordagem defensiva de "Polling Local":
- O LiveView inicia um `:timer.send_interval` que acorda a cada 1.000ms.
- A cada ciclo, o LiveView lê os dados **diretamente do ETS** (Memória RAM) usando `Cache.lookup/1`. O banco de dados SQLite nunca é tocado para a renderização da tela.
- **Vantagem de Escala:** Se 50 engenheiros abrirem o dashboard, teremos apenas 50 consultas ultra-rápidas no ETS por segundo, em vez de 50 * N_eventos sobrecarregando o PubSub.

## 4. UI e UX
O dashboard foi estilizado com Tailwind CSS focando em um visual industrial (Dark Mode). Máquinas em estado `critical` (`temperatura >= 100°C`) ganham bordas vermelhas e um efeito visual de `animate-pulse` para chamar a atenção imediata do operador.
