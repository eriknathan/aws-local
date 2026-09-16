# Plano de implementação — melhorias na arquitetura FlowQueue

Este documento é **só o plano**, sem código ainda. Cobre as 7 melhorias
discutidas para a arquitetura FlowQueue (ver `flowqueue.md`), com o que
muda em Terraform, decisões em aberto e uma ordem de prioridade sugerida.

Prioridade sugerida: **1 → 5 → 2+4 → 7 → 6 → 3** (do bug latente mais sério
para o hardening mais caro/dependente de infraestrutura externa).

---

## 1. Consistência S3 + DynamoDB + SQS (idempotência)

**Status: implementado no Terraform** — `visibility_timeout_seconds`
exposto/ajustado (ver abaixo) e o contrato de idempotência documentado em
`backend-idempotencia.md`. A lógica dos passos 1–4 continua sendo código de
aplicação do Backend, fora deste repositório.

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

**O que mudou em Terraform**:
- `terraform/modules/messaging/variables.tf`: `visibility_timeout_seconds`
  passou de fixo em 30s pra default de 90s.
- `terraform/variables.tf` + `terraform/main.tf`: novo
  `var.sqs_visibility_timeout_seconds` (default `90`), exposto na raiz e
  passado pro módulo — ajustável via `-var`/`terraform.tfvars` sem editar o
  módulo.
- Nenhum recurso novo — DynamoDB já é schemaless o suficiente para os
  atributos extras (`receipt_key`, `receipt_version_id`, `status`).
- Padrão documentado em `backend-idempotencia.md`, com referência também no
  comentário do bloco `module "backend"` em `terraform/main.tf`.

**Decisão confirmada**: fila principal continua *standard* SQS (throughput
maior), com idempotência resolvida na aplicação (Backend) — não foi
migrada para FIFO.

---

## 2. Reforçar a garantia dos 365 dias no S3

**Status: implementado no Terraform** — `aws_s3_bucket_policy` criado em
`terraform/modules/storage/main.tf` e testado na prática contra o Floci
(ver limitação encontrada abaixo).

**Situação atual**: o IAM do Backend (`terraform/main.tf`) já concede só `PutObject`,
`GetObject`, `GetObjectRetention` e `ListBucket` — **sem** `PutObjectRetention`
nem `s3:BypassGovernanceRetention`. Sem essas permissões, o Backend não
consegue setar uma retenção mais fraca no upload; todo objeto herda o
default do bucket (`COMPLIANCE`, 365 dias).

**O que mudou em Terraform** (defesa em profundidade,
`terraform/modules/storage/main.tf`):
- Novo `aws_s3_bucket_policy` no bucket de recibos, negando:
  - `s3:PutObjectRetention` e `s3:BypassGovernanceRetention` pra qualquer
    principal (ninguém deveria precisar disso nesse bucket). **Testado
    contra o Floci: funciona** — `PutObjectRetention` e `DeleteObject` com
    bypass foram negados corretamente.
  - `s3:PutObject` que venha com o header `s3:object-lock-mode` diferente de
    `var.retention_mode` (impede downgrade de modo mesmo se algum papel
    futuro ganhar a permissão de `PutObjectRetention` por engano). **Gap do
    Floci encontrado ao testar**: essa condition key não é avaliada pelo
    emulador — um `PutObject` com `ObjectLockMode=GOVERNANCE` foi aceito
    mesmo com a policy negando. Documentado em `terraform/README.md`
    (seção de limitações conhecidas); a policy está correta e deve
    funcionar como desenhada contra a AWS real.
- **Limitação a documentar**: não dá pra expressar "retenção mínima de 365
  dias" como condição estática de bucket policy (a data-alvo é relativa a
  "agora", e a AWS não tem uma condition key pra isso) — o controle real é
  IAM least-privilege (já implementado) + trava de modo (novo, com a ressalva
  do Floci acima). Isso está no próprio comentário do recurso, não é
  enganar o usuário achando que o bucket policy garante o prazo sozinho.

---

## 3. Proteger a entrada pública (WAF + HTTPS + restringir ALB ao CloudFront)

**Status: implementado no Terraform.** Domínio confirmado:
`eriknathan.me` (registrado na Hostinger), usando o subdomínio
`flowqueue.eriknathan.me` (decisão sua, pra não interferir no que já
estiver no domínio raiz). Como o domínio não está no Route53, a validação
DNS do ACM é manual — ver `dns-validacao.md`.

**Mais cara e com mais dependências externas das sete** — as decisões que
estavam em aberto:
- **Domínio**: confirmado, `eriknathan.me` (Hostinger) → subdomínio
  `flowqueue.eriknathan.me`.
- Confirmado: CloudFront **crasha o provider Terraform contra o Floci** (bug
  já documentado no README) — segue sem mudança, o código está pronto pra
  AWS real mas não dá pra validar a distribution em si localmente.

**O que foi implementado em Terraform:**
- Novo `terraform/modules/certificates`: `aws_acm_certificate` + validação
  DNS. **Sem `aws_route53_record`** — o domínio está na Hostinger, não no
  Route53, então os registros de validação vão pros outputs do módulo pra
  criação manual (ver `dns-validacao.md`). Um cert pro CloudFront
  (`us-east-1`, via `provider "aws" { alias = "us_east_1" }` novo em
  `terraform/providers.tf`) e outro regional pro ALB.
- `terraform/modules/edge`:
  - `aws_lb_listener` HTTPS (443) usando o cert regional; listener HTTP (80)
    vira redirect 301 pra HTTPS quando `enable_https = true`.
  - `aws_cloudfront_distribution.viewer_certificate` passa a usar o cert
    ACM em vez do `cloudfront_default_certificate`.
  - Origem do CloudFront ganha um `custom_header` com um segredo (gerado via
    `random_password`, guardado no Parameter Store) — o ALB só aceita
    tráfego que tenha esse header. Só ativo quando `enable_https` **e**
    `enable_cloudfront` estão os dois ligados.
  - Novo `data "aws_ec2_managed_prefix_list"` para
    `com.amazonaws.global.cloudfront.origin-facing`, usado no security group
    do ALB no lugar de `0.0.0.0/0` (mesma condição acima).
  - Novo `aws_lb_listener_rule` no listener HTTPS: se o header secreto não
    bater, retorna 403 fixo (`fixed_response`) — bloqueia quem tentar acessar
    o ALB direto, mesmo sabendo o DNS.
- Novo `terraform/modules/waf`: `aws_wafv2_web_acl` (scope `CLOUDFRONT`, região
  `us-east-1`) com `AWSManagedRulesCommonRuleSet` +
  `AWSManagedRulesKnownBadInputsRuleSet`; associado à distribution via
  `web_acl_id`. Criado só quando `enable_cloudfront = true`.
- `terraform/variables.tf`: novo `domain_name` (default `null` — item 3
  inteiro fica desligado sem domínio, comportamento local não muda).
- Novo `environments/aws/terraform.tfvars.example` com os valores pra
  deploy real (`domain_name = "flowqueue.eriknathan.me"`,
  `enable_cloudfront = true`).

**Testado contra o Floci** (`module.certificates` e `module.waf` isolados,
com `domain_name`/`enable_cloudfront` via `-var`, depois revertido — não
ficou no `environments/local/terraform.tfvars`): os dois criaram sem erro.
Achado interessante: o Floci **valida o certificado ACM na hora**, sem
precisar do CNAME real — bom pra saber que esse teste local não cobre o
fluxo de validação manual de verdade (detalhes em `terraform/README.md`).
O restante (listener HTTPS, redirect, header secreto, CloudFront com WAF)
não dá pra testar localmente por causa dos bugs já conhecidos do Floci
(`CreateListener` 500 e CloudFront crashando o provider) — só
`terraform validate`/`plan` confirmam a sintaxe e o grafo de dependências.

---

## 4. VPC Endpoints

**Status: implementado no Terraform, os dois grupos** — testado contra o
Floci, os 6 endpoints ficaram `available` sem erro.

**Gateway endpoints (S3 e DynamoDB): sem custo por hora, baixíssimo risco —
plano é só fazer, sem debate de prioridade.**

**O que mudou em Terraform**:
- `terraform/modules/network`: dois novos `aws_vpc_endpoint` (`vpc_endpoint_type =
  "Gateway"`) para `com.amazonaws.<region>.s3` e
  `com.amazonaws.<region>.dynamodb`, associados às route tables privadas
  (`aws_route_table.private[*]`) já existentes. Confirmado via
  `describe_vpc_endpoints` que os dois `route_table_ids` batem com as duas
  route tables privadas.
- Outputs novos: `s3_gateway_endpoint_id`, `dynamodb_gateway_endpoint_id`,
  `interface_endpoint_ids` (map serviço → id).

**Interface endpoints (SQS, SSM/SSM Messages/EC2 Messages): tem custo por
hora + por AZ — decisão do usuário: implementar mesmo assim, já que o
ambiente roda no Floci (emulador local, sem cobrança real).**
- `aws_vpc_endpoint` (`vpc_endpoint_type = "Interface"`) pra `sqs`, `ssm`,
  `ssmmessages` e `ec2messages`, um security group novo
  (`aws_security_group.interface_endpoints`) liberando 443 a partir do CIDR
  da VPC, `private_dns_enabled = true`. ENIs ficam nas duas sub-redes
  privadas de Backend (uma por AZ) — Frontend alcança via roteamento local
  da VPC, sem precisar de ENI própria.
- Isso cobre o pré-requisito pro Session Manager funcionar **sem** NAT
  Gateway (os três juntos: `ssm`, `ssmmessages`, `ec2messages`) — a
  arquitetura atual ainda tem NAT Gateway, então isso é redundância
  proposital, não uma remoção de dependência.

---

## 5. Scaling por demanda real + alarmes CloudWatch

**Status: implementado no Terraform e testado contra o Floci** — decisões
confirmadas: step scaling clássico pro Backend (opção "a"), tópico SNS sem
inscrição de e-mail por enquanto. Ver limitações do Floci encontradas ao
final desta seção.

**Maior lacuna funcional hoje** (situação antes desta implementação): os ASGs (`terraform/modules/compute`) só têm
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

**O que foi implementado:**
- `terraform/modules/compute`: novas variáveis genéricas
  `enable_target_tracking_scaling`/`enable_step_scaling` (+ suporte), com
  `aws_autoscaling_policy` do tipo `TargetTrackingScaling` ou `StepScaling`
  (scale-out e scale-in separados) criadas conforme o caller.
- `terraform/modules/edge`: novos outputs `alb_arn_suffix` e
  `target_group_arn_suffix`, necessários pro `resource_label` do target
  tracking e pra dimensão `LoadBalancer` dos alarmes do ALB.
- **Frontend**: `enable_target_tracking_scaling = true`,
  `ALBRequestCountPerTarget`, alvo em `var.frontend_target_tracking_request_count`
  (default `750`, dentro da faixa 500–1000 sugerida).
- **Backend**: `enable_step_scaling = true` (opção "a" confirmada) — as
  duas policies (`step_scale_out`/`step_scale_in`) ficam em
  `modules/compute`; o alarme que as aciona fica em `modules/observability`
  (depende de métrica de outro módulo, SQS).
- Novo `terraform/modules/observability`: `aws_sns_topic` (+
  `aws_sns_topic_subscription` opcional via `var.alarm_email`, `null` por
  padrão — decisão confirmada de não inscrever e-mail agora), e 6
  `aws_cloudwatch_metric_alarm`: backlog da fila (scale-out/scale-in do
  Backend), idade da mensagem mais antiga, DLQ não vazia, 5xx do ALB,
  latência do ALB.
- `terraform/providers.tf`: **`sns` e `cloudwatch` precisaram ser
  adicionados ao bloco `endpoints`** — sem isso o provider tentava falar
  com a AWS real (não o Floci) pra esses dois serviços, e falhava com
  `InvalidClientTokenId`. Não é limitação do Floci, era gap na nossa
  config — só faltava porque nenhum módulo anterior usava SNS/CloudWatch.

**Limitações do Floci encontradas ao testar** (detalhes em
`terraform/README.md`): drift permanente (não some com um `apply` extra,
diferente do drift já conhecido do `launch_template`) em
`aws_cloudwatch_metric_alarm.datapoints_to_alarm` (cosmético) e em
`aws_autoscaling_policy` do tipo `TargetTrackingScaling` — o Floci descarta
o `resource_label` de `predefined_metric_specification` no *read* e sempre
devolve `enabled = false`. Não afeta o funcionamento local (a policy foi
criada e existe), mas suja o `terraform plan` permanentemente enquanto isso
não for corrigido no Floci.

---

## 6. API de status/download do recibo (URL pré-assinada)

**Status: implementado no Terraform e testado contra o Floci** — decisões
confirmadas: Frontend existente serve a API; **escopo expandido** em
relação ao plano original pra incluir autenticação via Amazon Cognito
(decisão sua). Contrato completo em `frontend-auth.md`.

**Decisões que estavam em aberto, agora confirmadas:**
- Quem serve a API: **Frontend existente** (não um componente novo).
- Autenticação: **Cognito** (não estava no plano original — o plano previa
  "sem mexer em autenticação por enquanto"; você pediu pra incluir agora).

**O que foi implementado em Terraform**:
- Novo `terraform/modules/auth`: `aws_cognito_user_pool` (login por
  e-mail) + `aws_cognito_user_pool_client` sem secret. **Testado na
  prática**: criei um usuário e fiz login contra o Floci
  (`AdminCreateUser` + `AdminInitiateAuth`), recebi um `IdToken` JWT válido
  com os claims esperados (`sub`, `email`, `aud`, `iss`, `token_use`).
- `terraform/main.tf`, `module "frontend"`: ganhou `dynamodb:GetItem`/
  `Query` na tabela de pedidos (checar dono + status) e `s3:GetObject` em
  `${module.storage.bucket_arn}/*` (gerar a URL pré-assinada — bucket
  continua privado).
- IDs do Cognito publicados no Parameter Store
  (`/flowqueue/auth/user-pool-id`, `-client-id`, `-issuer-url`).
- `terraform/providers.tf`: `cognitoidp` adicionado ao bloco `endpoints`
  (mesmo gap do item 5 — serviço novo que nenhum módulo anterior usava).
- A geração da própria URL pré-assinada (`GetObject` presigned, TTL curto,
  tipo 60–300s) e a validação do JWT continuam sendo código de aplicação,
  fora do escopo do Terraform — contrato documentado em
  `frontend-auth.md`.

**Limitação do Floci encontrada ao testar**: o `issuer_url` que o Terraform
publica (via atributo `endpoint` do user pool) não bate com o `iss` real
dentro do JWT emitido pelo Floci — o primeiro vem no formato de AWS real,
o segundo aponta pro próprio `localhost:4566`. Detalhes em
`terraform/README.md` e `frontend-auth.md`.

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
| 1. Idempotência | `terraform/modules/messaging` (timeout) ✅, `backend-idempotencia.md` ✅ | Resolvida: standard + idempotência na aplicação |
| 2. Retenção S3 | `terraform/modules/storage` (bucket policy nova) ✅ | Não |
| 3. WAF/HTTPS/ALB↔CloudFront | `terraform/modules/edge` ✅, `terraform/modules/certificates` (novo) ✅, `terraform/modules/waf` (novo) ✅, `terraform/providers.tf` ✅ | Resolvida: flowqueue.eriknathan.me, validação DNS manual |
| 4. VPC Endpoints | `terraform/modules/network` ✅ (Gateway + Interface) | Resolvida: implementar os dois |
| 5. Scaling + alarmes | `terraform/modules/compute` ✅, `terraform/modules/edge` ✅, `terraform/modules/observability` (novo) ✅, `terraform/providers.tf` ✅ | Resolvida: step scaling (a) + SNS sem e-mail por ora |
| 6. API + presigned URL | `terraform/main.tf` (IAM do Frontend) ✅, `terraform/modules/auth` (novo) ✅ | Resolvida: Frontend existente + Cognito |
| 7. Diagrama | `diagrams/` | Qual arquivo é o de referência |
