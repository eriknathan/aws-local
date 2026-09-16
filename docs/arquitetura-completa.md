# FlowQueue — Arquitetura Completa

> Referência: `diagrams/arquitetura-completa.drawio` (+ `.png`).

Este documento explica a versão **completa** da arquitetura **FlowQueue** —
o mesmo sistema desacoplado por fila do desenho original (`flowqueue.md`),
agora com borda protegida, autenticação de usuário final, rede mais fechada,
escala por demanda real e observabilidade.

---

## 1. Visão geral

FlowQueue é um sistema web multi-camada, desacoplado por fila, rodando
dentro de uma VPC na AWS e replicado em duas Zonas de Disponibilidade. A
ideia central: separar quem **recebe** o pedido (Frontend) de quem
**processa** o pedido (Backend), usando o **Amazon SQS** como intermediário
— assim um pico de tráfego na entrada não sobrecarrega o processamento, e
uma lentidão no processamento não trava a experiência de quem está
enviando pedidos.

A versão completa acrescenta ao desenho original:

- **Borda protegida**: WAF + HTTPS de ponta a ponta + o ALB só aceita
  tráfego que já passou pelo CloudFront.
- **Autenticação de usuário final**: quem baixa o recibo de um pedido
  precisa provar que é o dono, via Cognito.
- **Rede mais fechada e mais barata**: VPC Endpoints tiram tráfego AWS→AWS
  do caminho do NAT Gateway.
- **Escala de verdade**: cada camada escala pela métrica que faz sentido
  pra ela (requisições por instância no Frontend, backlog da fila no
  Backend) — em vez de capacidade fixa.
- **Observabilidade**: alarmes cobrindo os jeitos mais prováveis desse
  sistema falhar silenciosamente (fila enchendo, DLQ recebendo, ALB
  devolvendo erro).

---

## 2. Como ler o diagrama

- **Cores**: roxo = entrada web · rosa = mensageria · azul = DynamoDB ·
  verde = recibos no S3 · vermelho = segurança/identidade (WAF, ACM,
  Cognito) · cinza = rede/operação.
- **Seta cheia**: chamada de API, saindo de quem a inicia.
- **Tracejado**: associação, fluxo complementar ou redrive — não é uma
  chamada direta de request/response.
- As setas que saem do ALB e dos ASGs saem do **grupo** (não de uma
  instância específica): valem igualmente para as duas AZs.
- O usuário aparece duas vezes de propósito — a entrada ① (enviar pedido) e
  o download ⑨ (baixar recibo) são fluxos distintos, com autenticação
  diferente (nenhuma vs. Cognito).

---

## 3. Componentes, por camada

### 3.1 Borda global (fora da região, replicado mundialmente)

**AWS WAF**
Web ACL associado ao CloudFront, com regras gerenciadas da AWS (proteções
genéricas contra padrões de ataque web e exploits conhecidos). É a primeira
linha de defesa — filtra requisições maliciosas antes de gastar qualquer
recurso da aplicação com elas.

**Amazon CloudFront**
CDN e ponto de entrada público único. Termina TLS pro cliente, encaminha ao
ALB de origem por HTTPS, e injeta um **header secreto** em toda requisição
que envia à origem — é esse header que o ALB exige pra aceitar tráfego,
impedindo que alguém acesse o ALB direto, pulando o CloudFront (e o WAF).

**ACM (Certificate Manager)**
Dois certificados: um regional (pro listener HTTPS do ALB) e um em
`us-east-1` (exigido pelo CloudFront, independente da região principal).
Validação por DNS.

### 3.2 Rede (VPC)

**VPC + Internet Gateway**
Isola toda a aplicação numa rede privada. O IGW é o único ponto de
entrada/saída direta pra internet, e só as sub-redes públicas o usam.

**Sub-redes** (uma de cada por AZ, duas AZs):
- **Pública**: hospeda o ALB e os NAT Gateways.
- **Privada de Frontend**: instâncias de Frontend, sem IP público.
- **Privada de Backend**: instâncias de Backend, sem IP público.

**NAT Gateway** (um por AZ) — cada sub-rede privada roteia sua saída pro
NAT da própria AZ, não pelo NAT da AZ vizinha (evita tráfego cross-AZ
desnecessário e mantém a AZ independente em caso de falha da outra).

**Application Load Balancer**
Um único ALB, presente nas duas sub-redes públicas (uma AZ cada). Dois
listeners:
- **HTTPS**: ação padrão é bloquear — só quem chega com o header secreto do
  CloudFront é encaminhado de verdade pro Frontend.
- **HTTP**: vira redirect pra HTTPS.

O security group do ALB aceita conexão só dos IPs de saída do CloudFront
(via uma lista gerenciada pela própria AWS) — ninguém mais consegue nem
abrir uma conexão TCP com o ALB.

### 3.3 VPC Endpoints

Tráfego entre as instâncias e os serviços AWS que a aplicação usa não
precisa sair pelo NAT Gateway pra depois entrar de volta na rede AWS:

- **Gateway** (sem custo por hora): S3 e DynamoDB, associados às rotas das
  sub-redes privadas.
- **Interface** (custo por hora + por AZ): SQS, Session Manager e seus
  serviços de suporte — presentes nas duas AZs.

Chamadas a APIs *externas* (fora da AWS) continuam saindo pelo NAT →
Internet Gateway normalmente — os endpoints só cobrem tráfego AWS→AWS.

### 3.4 Camada de aplicação

**ASG Frontend** (sub-redes privadas 1/2)
Recebe tráfego HTTP do ALB, publica na fila principal, e serve a API de
status/download do recibo (só leitura no DynamoDB e no S3). Escala por
**requisições por instância** — mais tráfego web, mais instâncias.

**ASG Backend** (sub-redes privadas 3/4)
Consome a fila principal, persiste no DynamoDB e grava o recibo no S3. Sem
tráfego de entrada direto — nada chega nele por fora da fila. Escala por
**backlog da fila** — mais pedidos esperando, mais instâncias processando.

### 3.5 Mensageria

**Fila principal (SQS standard)**: recebe do Frontend, é consumida pelo
Backend. O tempo de invisibilidade da mensagem fica acima do pior caso de
processamento (consulta ao banco + upload do recibo + confirmação), pra
não reaparecer e ser reprocessada antes da hora. Depois de várias tentativas
falhas, a mensagem vai pra DLQ.

**DLQ**: mensagens que falharam repetidamente no processamento. Retida por
mais tempo que a fila principal — dá espaço pra investigar antes de
expirar.

A fila continua **standard**, não FIFO — throughput maior, com a
deduplicação de reentregas resolvida na lógica do Backend (consulta o
estado do pedido antes de gravar o recibo de novo), não pela fila em si.

### 3.6 Dados

**DynamoDB**: fonte de verdade dos pedidos. Guarda status do pedido, a
referência do recibo gravado no S3, e o dono do pedido (usado na checagem
de autorização do download). Gerenciado e escalável, sem servidor de banco
pra administrar.

### 3.7 Armazenamento

**S3**: bucket onde o Backend grava o recibo de cada pedido.
- **Object Lock, modo compliance, retenção mínima de 1 ano**: nem o dono da
  conta consegue apagar ou sobrescrever um objeto antes do prazo. Exige
  versionamento habilitado.
- **Política do bucket** reforça essa garantia: nega tentativas de
  enfraquecer a retenção ou de gravar um objeto com um modo de proteção
  mais fraco — mesmo que alguma permissão seja concedida por engano no
  futuro, a política do bucket barra.
- **Bloqueio total de acesso público** + criptografia dos dados em repouso.
- O Backend só tem permissão de gravar/ler o objeto e consultar a retenção
  — nunca de enfraquecê-la.

### 3.8 Autenticação

**Cognito User Pool**: login por e-mail. O usuário final autentica direto
(sem tela de login hospedada) e recebe um token (JWT).

O token é validado **localmente** pelo Frontend, contra a chave pública do
User Pool — não é uma chamada de API a cada requisição. O identificador
dentro do token é usado pra checar se quem está pedindo o recibo é
realmente o dono do pedido.

### 3.9 Operação e observabilidade

**Session Manager**: shell remoto administrativo nas instâncias, sem SSH,
sem bastion, sem porta aberta.

**Parameter Store**: URLs da fila/DLQ, nome da tabela, nome do bucket,
identificadores do Cognito e o header secreto do CloudFront — tudo
centralizado, nada hardcoded no código ou na imagem da instância.

**CloudWatch + SNS**: um tópico de notificação e alarmes cobrindo:

| Alarme | O que observa | Efeito |
|---|---|---|
| Backlog alto | Muitas mensagens esperando na fila principal | Aciona scale-out do Backend + notifica |
| Backlog baixo | Poucas mensagens esperando | Aciona scale-in do Backend |
| Fila envelhecendo | Mensagem mais antiga esperando há muito tempo | Notifica (processamento mais lento que a chegada de pedidos) |
| DLQ não vazia | Qualquer mensagem na fila de falhas | Notifica (falha recorrente, investigar) |
| Erros do ALB | Taxa de erro 5xx acima do esperado | Notifica |
| Latência do ALB | Tempo de resposta acima do esperado | Notifica |

---

## 4. Fluxo passo a passo

### 4.1 Envio de um pedido (①–⑨ no diagrama)

1. **①** Cliente chama a API por HTTPS no CloudFront — Web ACL do WAF na
   frente.
2. **②** CloudFront encaminha ao ALB por HTTPS, com o header secreto —
   security group do ALB só aceita conexão de IPs do CloudFront.
3. **③** ALB distribui em HTTP interno pro ASG Frontend (qualquer AZ).
4. **④** Frontend publica na fila principal e só então responde ao cliente
   (id do pedido), depois da confirmação do SQS.
5. **⑤** Backend recebe por long polling; só remove a mensagem da fila no
   fim do processamento bem-sucedido.
6. **⑥** Backend consulta o estado do pedido antes de tocar no S3 — uma
   reentrega vira checagem de duplicata, não reprocessamento.
7. **⑦** Grava o recibo no S3 com uma chave determinística — um recibo por
   pedido, retido 1 ano.
8. **⑧** Confirma o status no DynamoDB, guardando a referência do recibo —
   é esse registro que o Frontend lê pra responder consultas de status.
9. Se uma mensagem falha repetidamente, vai pra DLQ — dispara alarme, fica
   isolada pra investigação.

### 4.2 Download do recibo (autenticado)

1. Cliente faz login no Cognito e recebe um token.
2. Cliente chama a API de status/download do Frontend com esse token —
   mesmo caminho de borda do ①–③ acima.
3. Frontend valida o token localmente: assinatura, emissor, destinatário e
   expiração.
4. Frontend consulta o DynamoDB pelo pedido e compara o dono registrado com
   a identidade do token — sem bater, acesso negado.
5. Se o recibo já foi gravado, Frontend assina uma URL de download de curta
   duração pro S3 e devolve ao cliente — o bucket continua privado,
   ninguém acessa o objeto sem essa URL.

---

## 5. Alta disponibilidade e escalabilidade

- Toda a stack replicada em **2 AZs** — ALB, NAT Gateway, Frontend, Backend
  e os endpoints de interface têm presença em cada uma.
- **SQS como buffer**: pico de pedidos não vira pico de carga imediata no
  Backend — as mensagens esperam na fila.
- **Escala por métrica real**, não capacidade fixa: Frontend por
  requisições/instância (tráfego web), Backend por backlog da fila (volume
  de processamento) — cada camada escala pela demanda que efetivamente a
  afeta.
- DynamoDB e S3 são gerenciados e multi-AZ por natureza — não são pontos
  únicos de falha.
- Perda de uma AZ inteira: ALB e os dois ASGs seguem operando na AZ
  restante.

---

## 6. Segurança em profundidade

| Camada | Controle |
|---|---|
| Borda | WAF (regras gerenciadas AWS) na frente do CloudFront |
| Transporte | TLS de ponta a ponta — cliente↔CloudFront↔ALB (interno em HTTP, só dentro da VPC) |
| Rede | ALB só aceita os IPs de saída do CloudFront; Frontend/Backend em sub-redes privadas, sem IP público |
| Origem | Header secreto exclusivo do CloudFront — acesso direto ao ALB é bloqueado |
| Identidade | Cognito autentica o usuário final na API de download |
| Permissões | Least privilege por camada — Frontend não tem permissão de escrever no S3 nem de mexer em retenção; Backend não tem permissão administrativa |
| Dados em repouso | S3 com retenção mínima obrigatória + política anti-downgrade; criptografia habilitada |
| Segredos | Centralizados no Parameter Store; nada hardcoded |
| Acesso administrativo | Session Manager — sem SSH, sem porta aberta, sem bastion |

---

## 7. Falhas e recuperação

- **Falha entre gravar o S3 e confirmar o DynamoDB**: a mensagem volta a
  ficar visível na fila e é reprocessada — a checagem de idempotência
  (passo ⑥) evita duplicar o recibo.
- **Falha repetida**: mensagem vai pra DLQ, com alarme.
- **Perda de uma AZ**: ALB e os dois ASGs seguem na AZ restante.
- **Token expirado/inválido**: acesso negado na API de download, sem
  consultar o DynamoDB nem gerar URL.
- **Object Lock protege o recibo, não substitui a recuperação do sistema
  completo** — é uma garantia de imutabilidade do artefato, não um backup
  do estado da aplicação.

---

## 8. Resumo dos serviços utilizados

| Camada | Serviço AWS |
|---|---|
| Segurança de borda | AWS WAF (Web ACL) |
| CDN / Borda | Amazon CloudFront |
| Certificados | AWS Certificate Manager (ACM) |
| Balanceamento de carga | Application Load Balancer (HTTPS + HTTP→HTTPS redirect) |
| Rede | VPC, Internet Gateway, NAT Gateway, VPC Endpoints |
| Computação (Frontend) | EC2 + Auto Scaling Group (por requisições/instância) |
| Computação (Backend) | EC2 + Auto Scaling Group (por backlog da fila) |
| Mensageria | Amazon SQS (fila principal + DLQ) |
| Dados | Amazon DynamoDB |
| Armazenamento | Amazon S3 (com Object Lock) |
| Autenticação | Amazon Cognito (User Pool) |
| Operação/Segurança | AWS Systems Manager (Session Manager + Parameter Store) |
| Observabilidade | Amazon CloudWatch (alarmes) + Amazon SNS |
