# FlowQueue — Arquitetura Desacoplada de Processamento Assíncrono em AWS

> Fluxo de dados passando por filas para desacoplar frontend e backend.

Documentação de referência sobre a arquitetura **FlowQueue**: um desenho de referência para sistemas web multi-camada, altamente disponíveis, rodando dentro de uma VPC AWS e desacoplados por filas.

> Este documento descreve o desenho **original/base**. Para a versão com
> borda protegida (WAF/HTTPS), autenticação, VPC Endpoints, escala por
> demanda real e observabilidade, ver `arquitetura-completa.md`.

---

## 1. Visão geral

Esta arquitetura implementa um sistema web multi-camada, altamente disponível e desacoplado por filas, rodando inteiramente dentro de uma VPC na AWS, distribuído em duas Zonas de Disponibilidade (AZ A e AZ B).

A ideia central é separar a camada que recebe requisições dos usuários (Frontend) da camada que processa a lógica de negócio (Backend), usando **Amazon SQS** como intermediário. Isso torna o sistema resiliente a picos de carga, permite escalar cada camada de forma independente e evita que falhas no backend derrubem a experiência do usuário.

O nome **FlowQueue** representa bem a característica central da arquitetura: o fluxo de dados passando por filas para desacoplar frontend e backend.

---

## 2. Componentes principais

### 2.1 Camada de entrada (borda)

- **Amazon CloudFront**: CDN que recebe as requisições dos usuários, entrega conteúdo com baixa latência e atua como ponto de entrada público.
- **Application Load Balancer (ALB)**: Distribui o tráfego recebido do CloudFront entre as instâncias EC2 de Frontend nas duas AZs.
- **Internet Gateway**: Permite comunicação entre a VPC e a internet (tráfego de entrada/saída da camada pública).

### 2.2 Sub-redes públicas (por AZ)

- **NAT Gateway** (um por AZ): Permite que recursos em sub-redes privadas iniciem conexões de saída para a internet (ex.: atualizações, chamadas a APIs externas) sem serem expostos diretamente.

### 2.3 Camada de Frontend (sub-redes privadas 1 e 2)

- EC2 instâncias de Frontend gerenciadas por um **Auto Scaling Group**, replicadas nas duas AZs.
- Cada instância de Frontend, ao processar uma requisição, envia uma mensagem para uma fila SQS (*"Envia Mensagem"*), delegando o processamento pesado/assíncrono para o backend.

### 2.4 Camada de mensageria (SQS)

- **Fila SQS principal**: Recebe as mensagens enviadas pelas instâncias de Frontend das duas AZs, centralizando os eventos a serem processados.
- **Dead Letter Queue (DLQ)**: Recebe mensagens que falharam repetidamente no processamento, evitando loops infinitos e permitindo investigação posterior.
- As instâncias de Backend consomem (*"Recebe Mensagem"*) as mensagens da fila SQS principal para processá-las.

### 2.5 Camada de Backend (sub-redes privadas 3 e 4)

- EC2 instâncias de Backend gerenciadas por outro **Auto Scaling Group**, também replicadas nas duas AZs.
- Processam as mensagens consumidas da fila SQS e persistem/consultam dados no **Amazon DynamoDB**.

### 2.6 Camada de dados

- **Amazon DynamoDB**: Banco de dados NoSQL gerenciado, acessado pelas instâncias de Backend das duas AZs, funcionando como fonte de verdade dos dados da aplicação.

### 2.7 Camada de armazenamento (recibos de pedido)

- **Amazon S3**: Bucket onde o Backend anexa o recibo de cada pedido processado, após gravar os dados no DynamoDB.
- **S3 Object Lock (modo COMPLIANCE, retenção mínima de 1 ano)**: garante que nenhum recibo possa ser apagado ou sobrescrito antes do prazo mínimo de retenção — nem mesmo pelo dono da conta. Exige versionamento habilitado no bucket.
- **Bloqueio de acesso público**: o bucket não é acessível diretamente pela internet; apenas o Backend (via IAM) grava/lê os objetos.

### 2.8 Operação e segurança

- **AWS Systems Manager – Session Manager**: Permite acesso administrativo (shell) às instâncias EC2 sem necessidade de abrir portas SSH/RDP ou usar bastion hosts.
- **AWS Systems Manager – Parameter Store**: Armazena configurações e segredos (strings de conexão, chaves, parâmetros de ambiente) de forma centralizada e segura, consumidos pelas instâncias EC2.

---

## 3. Fluxo de dados (passo a passo)

1. O usuário acessa a aplicação; a requisição chega à Amazon CloudFront.
2. O CloudFront encaminha a requisição ao Application Load Balancer.
3. O ALB distribui a requisição para uma das instâncias EC2 de Frontend (AZ A ou AZ B), via Internet Gateway dentro da VPC.
4. A instância de Frontend processa a requisição e publica uma mensagem na fila SQS principal.
5. Uma instância EC2 de Backend (de qualquer AZ) consome a mensagem da fila SQS.
6. O Backend processa a mensagem e grava/consulta dados no DynamoDB.
7. O Backend anexa o recibo do pedido em um bucket S3, protegido por Object Lock (retenção mínima de 1 ano — o objeto não pode ser apagado nem sobrescrito antes desse prazo).
8. Caso uma mensagem falhe repetidamente no processamento, ela é redirecionada para a fila de mensagens mortas (DLQ) para tratamento manual ou reprocessamento posterior.
9. Recursos em sub-redes privadas que precisam de acesso à internet (ex.: para chamadas externas) saem via NAT Gateway.
10. Operadores administram as instâncias EC2 remotamente via Session Manager, e as aplicações buscam configurações/segredos no Parameter Store (incluindo o nome do bucket de recibos).

---

## 4. Alta disponibilidade e escalabilidade

- Toda a arquitetura é replicada em **2 Zonas de Disponibilidade**, eliminando ponto único de falha por AZ.
- **Auto Scaling Groups independentes** para Frontend e Backend permitem que cada camada escale de acordo com sua própria demanda (ex.: mais tráfego web vs. mais mensagens na fila).
- O uso de **SQS como buffer** entre as camadas absorve picos de tráfego: se o Backend estiver temporariamente sobrecarregado, as mensagens simplesmente aguardam na fila em vez de serem perdidas ou gerarem erro para o usuário.
- O **DynamoDB**, sendo um serviço gerenciado e multi-AZ por natureza, não é um ponto único de falha.
- O **S3**, assim como o DynamoDB, é multi-AZ por natureza (dados replicados entre múltiplas instalações dentro da região), o que garante alta durabilidade para os recibos armazenados.

---

## 5. Segurança e boas práticas observadas

- **Segmentação de rede**: instâncias de Frontend e Backend ficam em sub-redes privadas, sem exposição direta à internet; apenas o ALB fica acessível publicamente (via CloudFront).
- **Sem SSH/bastion exposto**: o acesso administrativo é feito via Session Manager, reduzindo superfície de ataque.
- **Segredos centralizados**: uso do Parameter Store evita hardcoding de credenciais nas instâncias.
- **Desacoplamento por filas**: reduz o "blast radius" de falhas — um problema no Backend não derruba o Frontend nem a experiência do usuário imediatamente.
- **Imutabilidade de registros sensíveis**: o Object Lock no bucket de recibos garante retenção mínima (compliance) mesmo contra exclusão acidental ou maliciosa, incluindo por credenciais com privilégios administrativos.

---

## 6. Possíveis pontos de atenção / melhorias futuras

- Avaliar o uso de **VPC Endpoints** para SQS, DynamoDB, S3 e SSM, reduzindo a dependência dos NAT Gateways (e custo associado) para tráfego que hoje sai para a internet.
- Definir **alarmes no CloudWatch** para o tamanho da fila principal e da DLQ, permitindo scaling proativo e alertas de falhas recorrentes.
- Documentar a **política de retry/redrive** da DLQ (quantas tentativas antes de mover a mensagem).
- Avaliar **WAF** na frente do CloudFront/ALB para proteção adicional contra ataques comuns na camada web.

---

## 7. Exemplo prático — Enunciado da questão

**Cenário**: Uma empresa de e-commerce está lançando uma nova funcionalidade de processamento de pedidos. O time de arquitetura precisa desenhar uma solução na AWS que atenda aos seguintes requisitos:

1. A aplicação deve ficar disponível para usuários da internet, com baixa latência de entrega de conteúdo estático e dinâmico.
2. O recebimento do pedido (camada web) deve ser independente do processamento do pedido (camada de negócio), de forma que picos de acesso ao site não sobrecarreguem o processamento, e vice-versa.
3. Se o processamento de um pedido falhar repetidamente (ex.: erro de integração com o sistema de pagamento), a mensagem não pode ser perdida — ela deve ser isolada para análise posterior, sem travar o processamento dos demais pedidos.
4. A solução deve suportar a falha completa de uma Zona de Disponibilidade sem indisponibilidade para o usuário final.
5. Cada camada da aplicação deve poder escalar automaticamente de forma independente, de acordo com sua própria demanda (tráfego web vs. volume de pedidos a processar).
6. Nenhuma instância de computação pode estar diretamente exposta à internet; o acesso administrativo deve ser feito sem abrir portas de SSH/RDP.
7. Credenciais e configurações sensíveis (ex.: chave de integração com o gateway de pagamento) não podem estar hardcoded no código ou na imagem da instância.
8. Os dados dos pedidos devem ser armazenados em um banco de dados gerenciado, escalável e altamente disponível, sem a necessidade de administrar servidores de banco de dados.

**Desafio**: Desenhe uma arquitetura AWS que atenda a todos esses requisitos.

### Resposta

A arquitetura FlowQueue, descrita neste documento, atende a todos os pontos do enunciado:

| Requisito do enunciado | Como o FlowQueue resolve |
|---|---|
| 1. Baixa latência / disponibilidade pública | CloudFront + ALB na borda da rede |
| 2. Independência entre camada web e camada de negócio | Frontend e Backend desacoplados via fila SQS |
| 3. Mensagens com falha não podem ser perdidas | Dead Letter Queue (DLQ) isola mensagens que falharam repetidamente |
| 4. Tolerância à falha de uma AZ inteira | Toda a stack (Frontend, Backend, NAT Gateway) replicada nas AZs A e B |
| 5. Escalonamento independente por camada | Dois Auto Scaling Groups distintos (Frontend e Backend) |
| 6. Sem exposição direta e sem SSH aberto | Instâncias em sub-redes privadas; acesso via Session Manager |
| 7. Sem credenciais hardcoded | Parameter Store centraliza configurações e segredos |
| 8. Banco de dados gerenciado e escalável | Amazon DynamoDB |

Esse tipo de exercício é comum em provas de certificação AWS (ex.: Solutions Architect Associate), justamente porque combina os temas de desacoplamento com filas, alta disponibilidade multi-AZ, escalabilidade automática e segurança de acesso — todos presentes nesta arquitetura.

---

## 8. Resumo dos serviços utilizados

| Camada | Serviço AWS |
|---|---|
| CDN / Borda | Amazon CloudFront |
| Balanceamento de carga | Application Load Balancer |
| Rede | VPC, Internet Gateway, NAT Gateway |
| Computação (Frontend) | EC2 + Auto Scaling Group |
| Computação (Backend) | EC2 + Auto Scaling Group |
| Mensageria | Amazon SQS (fila principal + DLQ) |
| Dados | Amazon DynamoDB |
| Armazenamento | Amazon S3 (recibos de pedido, com Object Lock) |
| Operação/Segurança | AWS Systems Manager (Session Manager + Parameter Store) |
