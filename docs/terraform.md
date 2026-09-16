# Terraform — FlowQueue

Explicação do código Terraform em `terraform/`: como os arquivos se
organizam, o que cada módulo provisiona e como tudo se conecta. Para a
explicação da **arquitetura** em si (o que cada recurso AWS representa e o
fluxo de dados), ver `arquitetura-completa.md`. Para instruções de uso
(`terraform init/plan/apply`) e limitações conhecidas do Floci, ver
`terraform/README.md`.

---

## 1. Estrutura de pastas

```
terraform/
├── main.tf              # instancia e conecta todos os módulos
├── variables.tf          # variáveis de entrada da raiz
├── outputs.tf             # outputs expostos após o apply
├── providers.tf           # configuração do provider AWS (dois: default + us-east-1)
├── versions.tf             # versão mínima do Terraform e dos providers
├── environments/
│   ├── local/terraform.tfvars           # valores pra rodar contra o Floci
│   └── aws/terraform.tfvars.example      # modelo pra rodar contra a AWS real
└── modules/
    ├── network/         # VPC, sub-redes, NAT, VPC Endpoints
    ├── messaging/        # SQS (fila principal + DLQ)
    ├── database/          # DynamoDB
    ├── storage/            # S3 (recibos, Object Lock, bucket policy)
    ├── auth/                # Cognito User Pool
    ├── certificates/         # ACM (regional + us-east-1)
    ├── waf/                   # WAF Web ACL
    ├── edge/                   # ALB + CloudFront
    ├── compute/                 # ASG genérico (usado pra Frontend e Backend)
    ├── observability/             # CloudWatch + SNS
    └── parameters/                  # SSM Parameter Store
```

Cada módulo é independente (recebe tudo via variáveis, não referencia outro
módulo diretamente) — quem conecta um módulo ao outro é sempre o
`main.tf` da raiz, passando o output de um como input do próximo.

---

## 2. Providers (`providers.tf`)

Dois `provider "aws"` na raiz:

- **Default**: usado pela maioria dos módulos. Region, access/secret key e
  um bloco `endpoints` **condicional** — só existe quando
  `var.use_local_endpoint = true`, apontando cada serviço AWS usado
  (`ec2`, `sqs`, `dynamodb`, `s3`, `cognitoidp`, `acm`, `wafv2` etc.) pro
  endpoint único do Floci (`var.aws_endpoint_url`, default
  `http://localhost:4566`). Com `use_local_endpoint = false`, esse bloco
  simplesmente não é gerado e o provider fala com a AWS real, sem precisar
  mudar mais nada em nenhum módulo.
- **`alias = "us_east_1"`**: fixo em `us-east-1`, independente de
  `var.aws_region`. Só é usado por `modules/certificates` (certificado do
  CloudFront) e `modules/waf` (Web ACL `scope = CLOUDFRONT`) — os dois
  únicos recursos que a AWS exige que existam nessa região específica.
  Passado explicitamente pra esses módulos via `providers = { aws.us_east_1
  = aws.us_east_1 }` no bloco do módulo.

**Cada serviço AWS novo usado por um módulo precisa ser adicionado na lista
de `endpoints`** do provider default (e, se for exclusivo de us-east-1,
também no provider `us_east_1`) — senão o Terraform tenta falar com a AWS
real mesmo rodando local, e falha com erro de credencial inválida.

---

## 3. Variáveis da raiz (`variables.tf`)

Agrupadas por assunto:

**Gerais**: `project_name` (prefixo de todos os nomes, default
`flowqueue`), `aws_region`, `tags`.

**Alvo (Floci vs. AWS real)**: `use_local_endpoint`, `aws_endpoint_url`,
`aws_access_key`/`aws_secret_key` (qualquer valor não vazio serve pro
Floci).

**Rede**: `vpc_cidr` (default `10.0.0.0/16`), `azs` (duas AZs).

**Compute**: `instance_type`, `frontend_ami_id`/`backend_ami_id`,
`*_min_size`/`*_max_size`/`*_desired_capacity` pras duas camadas (default
`2/4/2`).

**Mensageria**: `sqs_max_receive_count` (tentativas antes da DLQ, default
`5`), `sqs_visibility_timeout_seconds` (default `90`).

**Borda**: `enable_cloudfront`, `enable_alb_listener` — as duas ligadas por
padrão; existem porque o Floci tem bugs conhecidos nesses dois recursos
específicos (ver `terraform/README.md`), então dá pra desligar sem mexer
em mais nada.

**Armazenamento**: `receipts_retention_days` (default `365`),
`receipts_retention_mode` (`COMPLIANCE` ou `GOVERNANCE`).

**Scaling e observabilidade**: `frontend_target_tracking_request_count`
(default `750`), `alarm_email` (default `null` — sem inscrição no SNS).

**HTTPS/WAF**: `domain_name` (default `null`). É essa variável que liga ou
desliga todo o item de HTTPS/WAF de uma vez — sem domínio configurado, os
módulos `certificates`/`waf` nem são instanciados, e o ALB/CloudFront
seguem em HTTP puro.

---

## 4. Módulos

### 4.1 `network`

Provisiona a VPC inteira: `aws_vpc`, `aws_internet_gateway`, três pares de
sub-rede por AZ (pública, privada-frontend, privada-backend), um
`aws_nat_gateway` por AZ (com seu `aws_eip`), route tables e associações, e
os **VPC Endpoints**:

- Gateway (`aws_vpc_endpoint`, `vpc_endpoint_type = "Gateway"`) pra S3 e
  DynamoDB, associados às route tables privadas.
- Interface (`vpc_endpoint_type = "Interface"`) pra `sqs`, `ssm`,
  `ssmmessages`, `ec2messages`, via `for_each` sobre uma lista de nomes de
  serviço — um `aws_security_group` dedicado libera 443 só a partir do
  CIDR da VPC.

Variáveis principais: `name`, `vpc_cidr`, `azs`, `aws_region` (usado só pra
montar o `service_name` dos endpoints, tipo
`com.amazonaws.<region>.s3`). Outputs: IDs da VPC/sub-redes/NAT, e os IDs
dos endpoints.

### 4.2 `messaging`

Duas filas SQS: `aws_sqs_queue.main` (com `redrive_policy` apontando pra
`aws_sqs_queue.dlq`) e a DLQ em si. Variáveis:
`visibility_timeout_seconds`, `message_retention_seconds`,
`dlq_message_retention_seconds`, `max_receive_count`. Outputs: URL, ARN e
nome de cada fila (nome é usado depois como dimensão dos alarmes do
CloudWatch, que identificam a fila pelo nome, não pelo ARN).

### 4.3 `database`

Uma tabela `aws_dynamodb_table`, `billing_mode = "PAY_PER_REQUEST"`
(serverless), chave primária configurável (`hash_key`, default `id`).
Simples de propósito — o resto (índices, atributos extras) é decisão de
aplicação, não precisa existir em Terraform.

### 4.4 `storage`

O bucket de recibos e tudo que garante a retenção:

- `random_id.suffix` — sufixo aleatório no nome do bucket (nomes de bucket
  são globalmente únicos).
- `aws_s3_bucket` com `object_lock_enabled = true` (só pode ser ligado na
  criação).
- `aws_s3_bucket_versioning` (`Enabled` — pré-requisito do Object Lock).
- `aws_s3_bucket_object_lock_configuration` — `default_retention` com
  `mode`/`days` vindos de `var.retention_mode`/`var.retention_days`.
- `aws_s3_bucket_public_access_block` — tudo bloqueado.
- `aws_s3_bucket_server_side_encryption_configuration` — SSE-S3.
- `aws_s3_bucket_policy` — nega `s3:PutObjectRetention` e
  `s3:BypassGovernanceRetention` pra qualquer principal, e nega
  `s3:PutObject` cujo header `object-lock-mode` divirja de
  `var.retention_mode`.

### 4.5 `auth`

`aws_cognito_user_pool` (login por `email`, `password_policy` configurável
via `var.password_minimum_length`/`var.mfa_configuration`) +
`aws_cognito_user_pool_client` sem secret (`generate_secret = false`),
habilitado pros fluxos `ALLOW_USER_PASSWORD_AUTH`,
`ALLOW_USER_SRP_AUTH`, `ALLOW_REFRESH_TOKEN_AUTH`. Output `issuer_url`
monta a URL do issuer a partir do atributo computado `endpoint` do user
pool (usado por quem for validar o JWT).

### 4.6 `certificates`

Dois pares de certificado + validação:

- `aws_acm_certificate.regional` (`validation_method = "DNS"`) +
  `aws_acm_certificate_validation.regional` — pro listener HTTPS do ALB.
- `aws_acm_certificate.cloudfront`/`_validation.cloudfront`, só criados
  quando `var.create_cloudfront_certificate = true`, usando
  `provider = aws.us_east_1`.

Como o domínio não está no Route53, **não existe `aws_route53_record` de
validação aqui** — os registros a criar manualmente ficam nos outputs
`regional_validation_records`/`cloudfront_validation_records` (lista de
`name`/`type`/`value`, extraídos de `domain_validation_options` do
certificado). Os outputs de ARN vêm do recurso de *validation*, não do
certificado puro — isso cria uma dependência que só libera quem consome
(o listener HTTPS, o CloudFront) depois que a AWS confirmar o certificado
como emitido.

### 4.7 `waf`

Um único `aws_wafv2_web_acl` (`scope = "CLOUDFRONT"`, `provider =
aws.us_east_1`), com duas `rule` usando `managed_rule_group_statement`
(`AWSManagedRulesCommonRuleSet` e `AWSManagedRulesKnownBadInputsRuleSet`),
`default_action { allow {} }`. Output: `web_acl_arn`.

### 4.8 `edge`

O módulo mais denso — ALB e CloudFront, e a lógica de "só aceitar tráfego
que veio do CloudFront":

- `aws_security_group.alb` — os `ingress` são blocos `dynamic`: com
  `local.restrict_alb_to_cloudfront` (= `var.enable_https &&
  var.enable_cloudfront`) falso, libera 80/443 pra `0.0.0.0/0` (default);
  verdadeiro, troca por um único `ingress` de 443 restrito à
  `data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing"`.
- `aws_lb` + `aws_lb_target_group.frontend`.
- `aws_lb_listener.http` — forward direto (default) ou redirect 301 pra
  HTTPS quando `var.enable_https`.
- `aws_lb_listener.https` — só existe com `enable_https`. Ação default é
  `forward` (sem restrição) ou `fixed-response` 403 (com restrição).
- `aws_lb_listener_rule.https_cloudfront_only` — só existe com
  `local.restrict_alb_to_cloudfront`; usa `condition { http_header {...} }`
  pra checar `var.origin_secret_header_value` e só então faz o `forward`
  de verdade.
- `aws_cloudfront_distribution.this` — `count` por `var.enable_cloudfront`.
  `custom_origin_config.origin_protocol_policy` vira `https-only` (em vez
  de `http-only`) e ganha um `custom_header` com o segredo quando
  restringindo; `viewer_certificate` usa o ACM (`var.enable_https`) ou o
  certificado padrão do CloudFront; `web_acl_id = var.waf_web_acl_arn`.

Outputs incluem `alb_arn_suffix`/`target_group_arn_suffix` (usados como
dimensão de métrica pelo `observability` e pelo target tracking do
`compute`, respectivamente).

### 4.9 `compute`

Módulo genérico de Auto Scaling Group — instanciado **duas vezes** na raiz
(uma pro Frontend, uma pro Backend), cada vez com IAM, `ingress_rules` e
flags de scaling diferentes:

- `aws_security_group`, `aws_iam_role` (sempre com
  `AmazonSSMManagedInstanceCore` anexado — é isso que viabiliza o Session
  Manager), `aws_iam_role_policy.extra` (statements passados por quem
  instancia o módulo, via `var.extra_policy_statements`),
  `aws_iam_instance_profile`, `aws_launch_template`,
  `aws_autoscaling_group`.
- `aws_autoscaling_policy.target_tracking` — só com
  `var.enable_target_tracking_scaling`; usa
  `var.target_tracking_predefined_metric_type` +
  `var.target_tracking_resource_label` + `var.target_tracking_target_value`
  (é assim que o Frontend escala por `ALBRequestCountPerTarget`).
- `aws_autoscaling_policy.step_scale_out`/`step_scale_in` — só com
  `var.enable_step_scaling`; criam as policies de `StepScaling`, mas **sem
  alarme próprio** — quem aciona elas é um `aws_cloudwatch_metric_alarm` em
  `modules/observability`, que referencia o ARN dessas policies (por isso
  o módulo expõe `step_scale_out_policy_arn`/`step_scale_in_policy_arn`
  como output).

### 4.10 `observability`

`aws_sns_topic.alarms` (+ `aws_sns_topic_subscription.email`, só com
`var.alarm_email != null`) e seis `aws_cloudwatch_metric_alarm`:

| Recurso | Métrica/namespace | `alarm_actions` |
|---|---|---|
| `backend_scale_out` | `ApproximateNumberOfMessagesVisible` (AWS/SQS) > `var.queue_backlog_scale_out_threshold` | policy de scale-out do Backend + SNS |
| `backend_scale_in` | idem, `<` `var.queue_backlog_scale_in_threshold` | policy de scale-in do Backend |
| `queue_oldest_message_age` | `ApproximateAgeOfOldestMessage` (AWS/SQS) | SNS |
| `dlq_not_empty` | `ApproximateNumberOfMessagesVisible` na DLQ, `> 0` | SNS |
| `alb_5xx` | `HTTPCode_Target_5XX_Count` (AWS/ApplicationELB) | SNS |
| `alb_latency` | `TargetResponseTime` (AWS/ApplicationELB) | SNS |

As dimensões usam `main_queue_name`/`dlq_name` (nome da fila, não ARN) e
`alb_arn_suffix` — formato que o CloudWatch exige pra métricas de SQS e
ALB respectivamente.

### 4.11 `parameters`

Um único recurso, `aws_ssm_parameter.this`, com `for_each` sobre
`var.parameters` (mapa `nome => { value, type }`). Genérico de propósito —
quem decide quais parâmetros existem é sempre a raiz.

---

## 5. `main.tf` — como os módulos se conectam

Dois `locals` centrais:

```hcl
enable_https               = var.domain_name != null
restrict_alb_to_cloudfront = local.enable_https && var.enable_cloudfront
```

Esses dois booleanos é que decidem, em cascata, quais módulos/recursos
opcionais existem (`certificates`, `waf`, o header secreto, os listeners
HTTPS, a restrição de rede).

Ordem de instanciação (não estritamente necessária — o Terraform monta o
grafo de dependência sozinho a partir dos outputs referenciados — mas
organizada assim pra ficar legível):

1. `network` — não depende de nada.
2. `messaging`, `database`, `storage`, `auth` — independentes entre si.
3. `parameters` — depende dos outputs dos quatro acima (e,
   condicionalmente, do `random_password.origin_secret`).
4. `certificates`, `waf` — condicionais (`count`), independentes entre si.
5. `random_password.origin_secret` — condicional
   (`restrict_alb_to_cloudfront`).
6. `edge` — depende de `network` (subnets), `certificates` e `waf`
   (ARNs), e do `random_password` (header secreto).
7. `frontend`/`backend` (duas instâncias de `compute`) — dependem de
   `network`, `edge` (SG e ARNs pro target tracking), `messaging`,
   `database`, `storage`.
8. `observability` — depende de `messaging` (nomes das filas), `backend`
   (ARNs das policies de scaling) e `edge` (ARN do ALB).

Cada módulo condicional usa `count = <condição> ? 1 : 0` — por isso as
referências aos seus outputs em outros módulos sempre aparecem como
`module.x[0].output` dentro de uma expressão ternária que already checks a
mesma condição (ex.:
`local.enable_https ? module.certificates[0].regional_certificate_arn :
null`), nunca incondicional.

---

## 6. Outputs da raiz (`outputs.tf`)

Expõe só o que é útil pra operar o sistema de fora (URLs, nomes, ARNs) —
não replica todo output interno de cada módulo. Destaque:
`acm_dns_validation_records` — só populado quando `var.domain_name != null`,
lista os registros DNS que precisam ser criados manualmente (ver
`dns-validacao.md`).

---

## 7. Environments

- **`environments/local/terraform.tfvars`** (commitado, sem segredos reais
  — qualquer credencial serve pro Floci): aponta pro Floci
  (`use_local_endpoint = true`), com `enable_cloudfront`/
  `enable_alb_listener = false` contornando os bugs conhecidos do Floci, e
  sem `domain_name` (item de HTTPS/WAF desligado).
- **`environments/aws/terraform.tfvars.example`** (commitado como modelo;
  o arquivo real, `terraform.tfvars` nessa mesma pasta, é gitignorado):
  `use_local_endpoint = false`, `domain_name` configurado,
  `enable_cloudfront = true` — nenhum outro módulo precisa mudar pra
  migrar de Floci pra AWS real, só essas variáveis.

---

## 8. Uso básico

```bash
cd terraform
terraform init
terraform plan  -var-file=environments/local/terraform.tfvars
terraform apply -var-file=environments/local/terraform.tfvars
```

Pra instruções completas (apply incremental, `terraform destroy`, migração
pra AWS real) e a lista de limitações conhecidas do Floci encontradas
testando cada módulo, ver `terraform/README.md`.
