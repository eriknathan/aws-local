# Terraform — FlowQueue

Provisiona a arquitetura descrita em `../docs/flowqueue.md` de forma modular
(ver `modules/`), apontando por padrão para o **Floci** local.

## Pré-requisitos

O Floci precisa estar no ar (raiz do repo):

```bash
make up
```

## Uso

```bash
cd terraform
terraform init
terraform plan  -var-file=environments/local/terraform.tfvars
terraform apply -var-file=environments/local/terraform.tfvars
```

Ou, a partir da raiz do repo, usando os atalhos do `Makefile`:

```bash
make tf-init
make tf-plan
make tf-apply
```

### Apply incremental (recomendado na primeira vez)

Os módulos têm maturidade diferente no Floci (ver plano/riscos). Para isolar
problemas, aplique em camadas:

```bash
terraform apply -var-file=environments/local/terraform.tfvars -target=module.network
terraform apply -var-file=environments/local/terraform.tfvars -target=module.messaging -target=module.database -target=module.parameters
terraform apply -var-file=environments/local/terraform.tfvars -target=module.edge
terraform apply -var-file=environments/local/terraform.tfvars -target=module.frontend -target=module.backend
terraform apply -var-file=environments/local/terraform.tfvars   # sem -target, deve ficar sem diff
```

### Destruir

```bash
terraform destroy -var-file=environments/local/terraform.tfvars
# ou: make tf-destroy
```

## Limitações conhecidas do Floci (validadas na prática)

O `environments/local/terraform.tfvars` já vem configurado para contornar os
dois problemas abaixo. Um `terraform apply` completo, sem `-target`, sobe as
44 resources do zero sem erro nesse setup.

- **CloudFront quebra o provider da AWS.** `aws_cloudfront_distribution`
  crasha o `terraform-provider-aws` (panic/nil pointer em
  `flattenDefaultCacheBehavior`, logo após o create) — resposta do stub de
  CloudFront do Floci vem incompleta. Contornado com
  `enable_cloudfront = false`; o ALB já cobre a borda pública sozinho. Vale
  testar de novo em versões futuras do Floci.
- **`CreateListener` do ELBv2 retorna 500.** `InternalFailure: Unexpected
  error: null`, de forma determinística — reproduzido até com AWS CLI puro
  (sem Terraform), então não é um problema deste código. Contornado com
  `enable_alb_listener = false`; o target group já existe e o Frontend já
  está anexado a ele, só falta o listener em si.
- **ASG não sobe containers Docker reais.** `../docs/floci.md` descreve EC2 como
  rodando em containers Docker reais, mas instâncias criadas via Auto Scaling
  Group aparecem como `InService`/`Healthy` na API (com `InstanceId` válido)
  sem nenhum container correspondente rodando (`docker ps` não mostra nada).
  Parece ser uma lacuna específica do caminho ASG → EC2 (diferente de
  `run-instances` direto). Todas as instâncias também aparecem na mesma AZ,
  mesmo com subnets de duas AZs em `vpc_zone_identifier`.
- **Pequeno drift cosmético a cada `plan`.** Tags do `aws_ssm_parameter` e
  `security_groups` dentro de `network_interfaces` do `aws_launch_template`
  às vezes não voltam completos no *read* do Floci, gerando um "to change"
  inofensivo (não recria nada). Rodar `apply` de novo resolve; não é um bug
  do nosso código.
- **Drift permanente (não estabiliza) em `aws_autoscaling_policy` e
  `aws_cloudwatch_metric_alarm`.** Diferente do drift cosmético do
  `aws_launch_template` acima (que some depois de um `apply` extra), esses
  dois ficam em loop infinito — testado com `plan` → `apply` → `plan` de
  novo e o diff persiste, sempre os mesmos 11 recursos:
  - `aws_cloudwatch_metric_alarm`: o Floci sempre devolve
    `datapoints_to_alarm = <evaluation_periods>` no *read*, mesmo esse
    atributo nunca tendo sido definido no `.tf` (fica `null`, que pro
    Terraform é um valor válido e diferente de "igual a
    `evaluation_periods`"). Cosmético — não muda o comportamento do alarme.
  - `aws_autoscaling_policy` do tipo `TargetTrackingScaling`: o Floci
    devolve `enabled = false` no *read* (criado como `true`, o default) e
    **descarta o `resource_label`** dentro de
    `predefined_metric_specification` — esse aqui é mais sério, porque sem
    `resource_label` a métrica `ALBRequestCountPerTarget` não teria como
    saber qual target group medir contra a AWS real. Não reproduzi o mesmo
    problema nas policies `StepScaling` do Backend (essas não têm
    `predefined_metric_specification`).
  Sem impacto prático pra rodar `apply`/`plan` (não recria nada, só marca
  "to change" toda vez) — mas não dá pra usar `terraform plan` como sinal
  de "ambiente sem drift" enquanto esses recursos existirem. Vale re-testar
  em versões futuras do Floci.
- **ACM: `aws_acm_certificate_validation` valida na hora, sem precisar do
  CNAME real.** Testado (`module.certificates`, item 3 de
  `../docs/melhorias.md`): pedi um certificado DNS-validated pro Floci e o
  `aws_acm_certificate_validation` concluiu em ~0s, sem eu ter criado
  nenhum registro DNS. Conveniente pra testar local, mas quer dizer que
  esse módulo **não valida o fluxo real** (que exige criar o CNAME
  manualmente na Hostinger e esperar a AWS confirmar — ver
  `../docs/dns-validacao.md`). `aws_wafv2_web_acl` (scope `CLOUDFRONT`)
  também criou sem erro no Floci.
- **`aws_cognito_user_pool.endpoint` não bate com o `iss` real do JWT
  emitido.** Testado na prática: criei um usuário (`AdminCreateUser` +
  `AdminSetUserPassword`) e fiz login (`AdminInitiateAuth`,
  `ADMIN_USER_PASSWORD_AUTH`) contra o Floci. O `IdToken` recebido tem
  `iss = "http://localhost:4566/<user-pool-id>"` (o próprio endpoint do
  Floci) — mas o atributo `endpoint` que o Terraform lê de volta do
  `DescribeUserPool` é `cognito-idp.us-east-1.amazonaws.com/<user-pool-id>`
  (formato de AWS real, sem refletir o `FLOCI_BASE_URL`). Ou seja, o
  `issuer_url` que `modules/auth` publica no Parameter Store **não bate com
  o `iss` real dos tokens localmente** — uma validação de JWT que compare
  `iss` contra esse valor vai falhar contra o Floci mesmo com tudo
  correto. Contra a AWS real os dois deveriam bater. Documentado também em
  `../docs/frontend-auth.md`.
- **Bucket policy: condition key `s3:object-lock-mode` não é avaliada.** A
  policy de `modules/storage` (item 2 de `../docs/melhorias.md`) nega
  `PutObject` quando o header `s3:object-lock-mode` vier diferente de
  `var.retention_mode` — no Floci, essa condição é ignorada e o `PutObject`
  passa normalmente com o modo que o cliente pedir (testado na prática:
  um upload com `ObjectLockMode=GOVERNANCE` foi aceito e o objeto ficou
  protegido em GOVERNANCE, não COMPLIANCE). As outras duas negações da
  mesma policy (`s3:PutObjectRetention` e `s3:BypassGovernanceRetention`)
  funcionam corretamente — só essa condition key específica não é
  respeitada. Vale re-testar em versões futuras do Floci; contra a AWS
  real a policy deve funcionar como desenhada.

Fora esses pontos, rede (VPC/subnets/NAT/IGW), SQS, DynamoDB, Parameter
Store, S3 (bucket + Object Lock + versionamento + encryption), o ALB em si
(load balancer + target group) e o compute (Launch Template + ASG + IAM)
funcionaram de forma limpa e idempotente.

## Armazenamento — recibos de pedido (S3 + Object Lock)

`modules/storage` cria o bucket onde o Backend anexa o recibo de cada
pedido, com retenção mínima real via **S3 Object Lock** (modo `COMPLIANCE`,
365 dias por padrão — `var.receipts_retention_days` /
`var.receipts_retention_mode`): nem o dono da conta consegue apagar ou
sobrescrever um objeto antes do prazo. Testado na prática contra o Floci —
`DeleteObject` de um objeto recém-criado retorna
`AccessDenied: Object is protected by COMPLIANCE retention`, com
`ObjectLockRetainUntilDate` = data de criação + 365 dias.

Ponto de atenção para o dia a dia: como o modo é `COMPLIANCE`, um
`terraform destroy` do bucket **vai falhar** (`BucketNotEmpty`) enquanto
houver qualquer objeto dentro da janela de retenção — isso é o
comportamento correto/esperado, não um bug. Em ambiente local isso só vira
problema se você subir objetos de teste manualmente (como fizemos na
validação); o bucket provisionado pelo Terraform sozinho, sem objetos, pode
ser destruído normalmente.

## Migrando para a AWS real

Nenhum módulo precisa mudar. Crie `environments/aws/terraform.tfvars`
(mantenha fora do git — já coberto pelo `.gitignore` da raiz) com:

```hcl
use_local_endpoint = false
aws_region         = "sua-regiao-real"
# access_key/secret_key: prefira variáveis de ambiente
# (AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY) ou um profile, não tfvars.
frontend_ami_id = "ami-xxxxxxxxxxxxxxxxx"
backend_ami_id  = "ami-xxxxxxxxxxxxxxxxx"
```

E rode `terraform apply -var-file=environments/aws/terraform.tfvars`.
