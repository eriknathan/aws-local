# Plano de implementação — melhorias na arquitetura FlowQueue

Este documento é **só o plano**, sem código ainda. Cobre as 7 melhorias
discutidas para a arquitetura FlowQueue (ver `flowqueue.md`), com o que
muda em Terraform, decisões em aberto e uma ordem de prioridade sugerida.

Prioridade sugerida: **1 → 5 → 2+4 → 7 → 6 → 3** (do bug latente mais sério
para o hardening mais caro/dependente de infraestrutura externa).

---

## 1. Consistência S3 + DynamoDB + SQS (idempotência)

**Problema**: o Backend pode subir o recibo no S3 e falhar antes de gravar o
DynamoDB (ou vice-versa), deixando estado inconsistente; reentregas da SQS
podem gerar recibos duplicados (versões extras no S3, retidas por 365 dias
por causa do Object Lock).

**Desenho proposto** (majoritariamente lógica de aplicação, não Terraform):

1. Backend recebe a mensagem, extrai `order_id` (chave de idempotência).
2. Consulta o DynamoDB por `order_id` **antes** de tocar no S3. Se já existe
   um registro com `status = "RECEIPT_STORED"`, pula direto para o passo 4
   (evita gerar versão nova no S3 numa reentrega).
3. Caso contrário: `PutObject` no S3 com chave determinística
   (`orders/<order_id>/receipt.pdf`), depois `UpdateItem` condicional no
   DynamoDB (`attribute_not_exists(receipt_version_id)` ou checagem de
   status) gravando `receipt_key` + `receipt_version_id` + `status`.
4. Só então chama `DeleteMessage` na fila.

Se o processo cair entre os passos 3 e 4, a mensagem volta a ficar visível
após o `visibility_timeout` e é reprocessada — o passo 2 evita reprocessar o
S3 à toa.

**O que muda em Terraform**:
- `terraform/modules/messaging/variables.tf`: revisar/expor
  `visibility_timeout_seconds` (hoje fixo em 30s) para garantir que fique
  acima do pior caso de tempo de processamento do Backend + upload do S3.
  Provavelmente sobe pra algo como 60–120s.
- Nenhum recurso novo — DynamoDB já é schemaless o suficiente para os
  atributos extras (`receipt_key`, `receipt_version_id`, `status`).
- Documentar o padrão acima como comentário em `terraform/modules/compute` (bloco do
  Backend) e/ou num novo `docs/backend-idempotencia.md`, já que é a lógica
  que qualquer implementação futura do Backend precisa seguir.

**Decisão em aberto**: manter a fila principal como *standard* SQS (throughput
maior, idempotência resolvida na aplicação, como acima) ou migrar para uma
fila **FIFO** (dedup nativo por `MessageDeduplicationId`, mas com teto de
throughput bem menor). Recomendo manter *standard* + idempotência na
aplicação, mas é uma escolha que vale confirmar com você antes de implementar.

---

## 2. Reforçar a garantia dos 365 dias no S3

**Situação atual**: o IAM do Backend (`terraform/main.tf`) já concede só `PutObject`,
`GetObject`, `GetObjectRetention` e `ListBucket` — **sem** `PutObjectRetention`
nem `s3:BypassGovernanceRetention`. Sem essas permissões, o Backend não
consegue setar uma retenção mais fraca no upload; todo objeto herda o
default do bucket (`COMPLIANCE`, 365 dias).

**O que muda em Terraform** (defesa em profundidade, `terraform/modules/storage/main.tf`):
- Novo `aws_s3_bucket_policy` no bucket de recibos, negando:
  - `s3:PutObjectRetention` e `s3:BypassGovernanceRetention` pra qualquer
    principal (ninguém deveria precisar disso nesse bucket).
  - `s3:PutObject` que venha com o header `s3:object-lock-mode` diferente de
    `COMPLIANCE` (impede downgrade de modo mesmo se algum papel futuro
    ganhar a permissão de `PutObjectRetention` por engano).
- **Limitação a documentar**: não dá pra expressar "retenção mínima de 365
  dias" como condição estática de bucket policy (a data-alvo é relativa a
  "agora", e a AWS não tem uma condition key pra isso) — o controle real é
  IAM least-privilege (já implementado) + trava de modo (novo). Isso vai
  para o próprio comentário do recurso, não é enganar o usuário achando que
  o bucket policy garante o prazo sozinho.

---

## 3. Proteger a entrada pública (WAF + HTTPS + restringir ALB ao CloudFront)

**Mais cara e com mais dependências externas das sete.** Precisa de decisões
suas antes de qualquer código:
- **Domínio**: existe um domínio real pra emitir certificado ACM (validação
  DNS), ou seguimos sem domínio próprio por enquanto (o que limita e/ou
  impede HTTPS de ponta a ponta)?
- Confirmado: CloudFront **crasha o provider Terraform contra o Floci** (bug
  já documentado no README). Dá pra escrever e deixar pronto para AWS real,
  mas não dá pra validar localmente até o Floci corrigir ou testarmos contra
  a AWS de verdade.

**O que muda em Terraform**, assumindo domínio disponível:
- Novo módulo `terraform/modules/certificates` (ou dentro de `terraform/modules/edge`):
  `aws_acm_certificate` + validação DNS (`aws_route53_record` +
  `aws_acm_certificate_validation`) — um para CloudFront (obrigatoriamente
  `us-east-1`, exige um `provider "aws" { alias = "us_east_1" }` extra em
  `terraform/providers.tf` se a região principal for outra) e outro regional pro ALB.
- `terraform/modules/edge`: 
  - `aws_lb_listener` HTTPS (443) usando o cert regional; listener HTTP (80)
    vira redirect 301 pra HTTPS.
  - `aws_cloudfront_distribution.viewer_certificate` passa a usar o cert
    ACM em vez do `cloudfront_default_certificate`.
  - Origem do CloudFront ganha um `custom_header` com um segredo (gerado via
    `random_password`, guardado no Parameter Store) — o ALB só aceita
    tráfego que tenha esse header.
  - Novo `data "aws_ec2_managed_prefix_list"` para
    `com.amazonaws.global.cloudfront.origin-facing`, usado no security group
    do ALB no lugar de `0.0.0.0/0`.
  - Novo `aws_lb_listener_rule` no listener HTTPS: se o header secreto não
    bater, retorna 403 fixo (`fixed_response`) — bloqueia quem tentar acessar
    o ALB direto, mesmo sabendo o DNS.
- Novo `terraform/modules/waf`: `aws_wafv2_web_acl` (scope `CLOUDFRONT`, região
  `us-east-1`) com regras gerenciadas da AWS (`AWSManagedRulesCommonRuleSet`,
  `AWSManagedRulesKnownBadInputsRuleSet` pelo menos); associado à distribution
  via `web_acl_id`.

---

## 4. VPC Endpoints

**Gateway endpoints (S3 e DynamoDB): sem custo por hora, baixíssimo risco —
plano é só fazer, sem debate de prioridade.**

**O que muda em Terraform**:
- `terraform/modules/network`: dois novos `aws_vpc_endpoint` (`vpc_endpoint_type =
  "Gateway"`) para `com.amazonaws.<region>.s3` e
  `com.amazonaws.<region>.dynamodb`, associados às route tables privadas
  (`aws_route_table.private[*]`) já existentes.
- Outputs novos: `s3_gateway_endpoint_id`, `dynamodb_gateway_endpoint_id`
  (não estritamente necessários, mas úteis pra depurar rota).

**Interface endpoints (SQS, SSM/SSM Messages/EC2 Messages): tem custo por
hora + por AZ — aqui sim é avaliação de custo x benefício.**
- Se decidirmos seguir: `aws_vpc_endpoint` (`vpc_endpoint_type =
  "Interface"`), um security group novo liberando 443 a partir do CIDR da
  VPC, `private_dns_enabled = true`, nas sub-redes privadas.
- Pré-requisito pro Session Manager funcionar **sem** NAT Gateway: precisa
  dos três juntos — `ssm`, `ssmmessages`, `ec2messages`.

---

## 5. Scaling por demanda real + alarmes CloudWatch

**Maior lacuna funcional hoje**: os ASGs (`terraform/modules/compute`) só têm
`min_size`/`max_size`/`desired_capacity` fixos — não existe nenhuma scaling
policy. A arquitetura promete "escala independente por camada" mas isso
ainda não está implementado de fato.

**O que muda em Terraform**:
- `terraform/modules/compute`: variáveis novas opcionais, ex.
  `enable_target_tracking_scaling` (bool) + `target_tracking_metric` +
  `target_tracking_value`, criando um `aws_autoscaling_policy` do tipo
  `TargetTrackingScaling` quando habilitado — mantém o módulo genérico
  (reutilizável pelos dois, mas configurado diferente por instância).
- **Frontend**: target tracking em `ALBRequestCountPerTarget`
  (`predefined_metric_type`, `resource_label` = ARN do target group, que já
  temos em `module.edge.target_group_arn`) — variável em `terraform/main.tf`, algo
  como 500–1000 req/target.
- **Backend**: não existe métrica pré-definida de "mensagens SQS por
  instância". Duas opções, a decidir:
  - (a) Step scaling clássico: `aws_cloudwatch_metric_alarm` em
    `ApproximateNumberOfMessagesVisible` da fila principal (com thresholds
    de warning/critical) acionando `aws_autoscaling_policy` do tipo
    `StepScaling`.
  - (b) Target tracking com métrica customizada de "backlog por instância"
    (mensagens visíveis ÷ instâncias em serviço) via
    `customized_metric_specification` — mais preciso, mais complexo de
    montar (precisa de uma métrica derivada, normalmente via CloudWatch Math
    ou uma Lambda publicando a métrica).
  - Recomendo (a) pra começar — mais simples, cobre o caso de uso.
- Novo `terraform/modules/observability` (ou os alarmes dentro de `terraform/modules/messaging`
  e `terraform/modules/compute`):
  - Alarme: `ApproximateAgeOfOldestMessage` da fila principal acima de X
    minutos (indica backlog crescendo mais rápido que o processamento).
  - Alarme: qualquer mensagem na DLQ (`ApproximateNumberOfMessagesVisible >
    0`) — falha recorrente, gatilho de investigação.
  - Alarme: taxa de erro/latência do ALB (`HTTPCode_Target_5XX_Count`,
    `TargetResponseTime`).
  - Precisa de um destino pros alarmes: `aws_sns_topic` +
    `aws_sns_topic_subscription` (e-mail, a definir com você).

---

## 6. API de status/download do recibo (URL pré-assinada)

**Decisão em aberto antes de qualquer Terraform**: quem serve essa API?
Reaproveitar o Frontend existente, ou um novo componente? E como o cliente
se autentica (hoje não existe nenhuma camada de auth de usuário final na
arquitetura — precisaria de algo tipo Amazon Cognito, que é um componente
novo, não mencionado até aqui)?

**O que muda em Terraform** (assumindo que o Frontend passa a servir essa
API, sem mexer em autenticação por enquanto):
- `terraform/main.tf`, `module "frontend"`: hoje o Frontend só tem permissão de
  `sqs:SendMessage`. Precisaria ganhar, de forma bem restrita:
  - `dynamodb:GetItem`/`Query` na tabela de pedidos (só pra checar dono +
    status).
  - `s3:GetObject` em `${module.storage.bucket_arn}/*` (só pra gerar a URL
    pré-assinada — o bucket continua privado, ninguém acessa o objeto
    direto).
- A geração da própria URL pré-assinada (`GetObject` presigned, TTL curto,
  tipo 60–300s) é código de aplicação, fora do escopo do Terraform.

---

## 7. Corrigir o diagrama (`diagrams/`)

- Há três arquivos em `diagrams/` (`arquitetura-referencia.drawio`,
  `arquitetura-completa.drawio`, `arquitetura-aprimorada.drawio`) e ainda não
  ficou definido qual é o de referência atual — os ajustes abaixo devem ser
  aplicados nele depois que isso for esclarecido.
- SQS, DynamoDB e SSM **já estão fora da VPC** desde o redesenho anterior —
  confirmar se o diagrama de referência já reflete isso.
- Ajustes pontuais que faltam:
  - Mostrar o ALB explicitamente presente nas duas sub-redes públicas (hoje
    é um ícone único numa faixa de cabeçalho da VPC).
  - Separar visualmente `ReceiveMessage` e `DeleteMessage` no lado do
    Backend (hoje só tem um ícone "Recebe Mensagem").
- Sem impacto em Terraform — é só documentação/diagrama.

---

## Resumo — arquivos que cada item toca

| Item | Módulos/arquivos Terraform afetados | Precisa de decisão sua antes? |
|---|---|---|
| 1. Idempotência | `terraform/modules/messaging` (timeout), docs | Standard vs. FIFO na fila |
| 2. Retenção S3 | `terraform/modules/storage` (bucket policy nova) | Não |
| 3. WAF/HTTPS/ALB↔CloudFront | `terraform/modules/edge`, `terraform/modules/certificates` (novo), `terraform/modules/waf` (novo), `terraform/providers.tf` | Domínio pra ACM |
| 4. VPC Endpoints | `terraform/modules/network` | Só interface endpoints (custo) |
| 5. Scaling + alarmes | `terraform/modules/compute`, `terraform/modules/messaging`, `terraform/modules/observability` (novo) | Destino dos alarmes (e-mail/SNS) |
| 6. API + presigned URL | `terraform/main.tf` (IAM do Frontend) | Quem serve a API + estratégia de auth |
| 7. Diagrama | `diagrams/` | Qual arquivo é o de referência |
