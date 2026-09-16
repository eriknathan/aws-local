locals {
  name        = var.project_name
  common_tags = merge(var.tags, { ManagedBy = "terraform" })

  # Item 3 (docs/melhorias.md) fica ligado só quando um domínio é
  # informado — sem isso, ALB/CloudFront seguem em HTTP puro (comportamento
  # anterior, o único testável hoje contra o Floci).
  enable_https               = var.domain_name != null
  restrict_alb_to_cloudfront = local.enable_https && var.enable_cloudfront
}

# 1. Rede — VPC, IGW, sub-redes públicas/frontend/backend, NAT Gateways
#    (docs/flowqueue.md seções 2.1, 2.2, 2.3, 2.5)
module "network" {
  source = "./modules/network"

  name       = local.name
  vpc_cidr   = var.vpc_cidr
  azs        = var.azs
  aws_region = var.aws_region
  tags       = local.common_tags
}

# 2. Mensageria — fila principal + DLQ (docs/flowqueue.md seção 2.4)
module "messaging" {
  source = "./modules/messaging"

  name                       = local.name
  max_receive_count          = var.sqs_max_receive_count
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds
  tags                       = local.common_tags
}

# 3. Dados — DynamoDB (docs/flowqueue.md seção 2.6)
module "database" {
  source = "./modules/database"

  table_name = "${local.name}-orders"
  tags       = local.common_tags
}

# 3b. Armazenamento — bucket S3 dos recibos de pedido anexados pelo Backend,
#     com retenção mínima via Object Lock (var.receipts_retention_days)
module "storage" {
  source = "./modules/storage"

  name           = local.name
  retention_days = var.receipts_retention_days
  retention_mode = var.receipts_retention_mode
  tags           = local.common_tags
}

# 3c. Autenticação — Cognito User Pool pro usuário final da API de
#     status/download do recibo (docs/melhorias.md item 6). Validação do
#     JWT é responsabilidade do Frontend — ver docs/frontend-auth.md.
module "auth" {
  source = "./modules/auth"

  name = local.name
  tags = local.common_tags
}

# 4. Operação — Parameter Store com config derivada de outros módulos
#    (docs/flowqueue.md seção 2.7)
module "parameters" {
  source = "./modules/parameters"

  parameters = merge(
    {
      "/${local.name}/queue/main-url"           = { value = module.messaging.main_queue_url, type = "String" }
      "/${local.name}/queue/dlq-url"            = { value = module.messaging.dlq_url, type = "String" }
      "/${local.name}/database/table-name"      = { value = module.database.table_name, type = "String" }
      "/${local.name}/storage/receipts-bucket"  = { value = module.storage.bucket_name, type = "String" }
      "/${local.name}/auth/user-pool-id"        = { value = module.auth.user_pool_id, type = "String" }
      "/${local.name}/auth/user-pool-client-id" = { value = module.auth.user_pool_client_id, type = "String" }
      "/${local.name}/auth/issuer-url"          = { value = module.auth.issuer_url, type = "String" }
    },
    local.restrict_alb_to_cloudfront ? {
      "/${local.name}/edge/origin-secret-header" = { value = random_password.origin_secret[0].result, type = "SecureString" }
    } : {}
  )

  tags = local.common_tags
}

# 4b. Certificados ACM (docs/melhorias.md item 3) — validação por DNS. O
#     domínio (var.domain_name) está na Hostinger, não no Route53, então
#     não dá pra criar o CNAME de validação via Terraform: ver os outputs
#     de module.certificates (ou docs/dns-validacao.md) pros registros a
#     criar manualmente. Só existe quando var.domain_name != null.
module "certificates" {
  count  = local.enable_https ? 1 : 0
  source = "./modules/certificates"

  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  domain_name                   = var.domain_name
  create_cloudfront_certificate = var.enable_cloudfront

  tags = local.common_tags
}

# 4c. WAF (docs/melhorias.md item 3) — Web ACL na frente do CloudFront.
#     Só existe quando o CloudFront está habilitado.
module "waf" {
  count  = var.enable_cloudfront ? 1 : 0
  source = "./modules/waf"

  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  name = local.name
  tags = local.common_tags
}

# Header secreto que o CloudFront envia ao ALB — restringe o ALB a só
# aceitar tráfego que já passou pelo CloudFront (docs/melhorias.md item 3).
resource "random_password" "origin_secret" {
  count = local.restrict_alb_to_cloudfront ? 1 : 0

  length  = 32
  special = false
}

# 5. Borda — ALB (+ CloudFront opcional) (docs/flowqueue.md seção 2.1)
module "edge" {
  source = "./modules/edge"

  name              = local.name
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  enable_cloudfront = var.enable_cloudfront
  enable_listener   = var.enable_alb_listener
  tags              = local.common_tags

  enable_https                   = local.enable_https
  acm_certificate_arn            = local.enable_https ? module.certificates[0].regional_certificate_arn : null
  acm_certificate_arn_cloudfront = local.enable_https && var.enable_cloudfront ? module.certificates[0].cloudfront_certificate_arn : null
  origin_secret_header_value     = local.restrict_alb_to_cloudfront ? random_password.origin_secret[0].result : null
  waf_web_acl_arn                = var.enable_cloudfront ? module.waf[0].web_acl_arn : null
}

# 6. Frontend — ASG nas sub-redes privadas 1/2, atrás do ALB, só publica na
#    fila principal (docs/flowqueue.md seção 2.3)
module "frontend" {
  source = "./modules/compute"

  name             = "${local.name}-frontend"
  vpc_id           = module.network.vpc_id
  subnet_ids       = module.network.private_frontend_subnet_ids
  ami_id           = var.frontend_ami_id
  instance_type    = var.instance_type
  min_size         = var.frontend_min_size
  max_size         = var.frontend_max_size
  desired_capacity = var.frontend_desired_capacity

  target_group_arns = [module.edge.target_group_arn]

  ingress_rules = [
    {
      from_port       = 80
      to_port         = 80
      protocol        = "tcp"
      security_groups = [module.edge.alb_security_group_id]
    }
  ]

  extra_policy_statements = [
    {
      Effect   = "Allow"
      Action   = ["sqs:SendMessage", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
      Resource = module.messaging.main_queue_arn
    },
    {
      # API de status/download do recibo (docs/melhorias.md item 6) — só
      # leitura, pra checar dono + status do pedido antes de gerar a URL
      # pré-assinada. Autenticação/autorização do usuário final (dono do
      # pedido) é feita via JWT do Cognito, validado em código de
      # aplicação — ver docs/frontend-auth.md.
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem", "dynamodb:Query"]
      Resource = module.database.table_arn
    },
    {
      # Só pra gerar a URL pré-assinada (GetObject) — o bucket continua
      # privado, ninguém acessa o objeto direto.
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${module.storage.bucket_arn}/*"
    }
  ]

  # Target tracking em requisições por instância — mantém o Frontend
  # escalado pra demanda de tráfego real (docs/melhorias.md item 5).
  enable_target_tracking_scaling         = true
  target_tracking_predefined_metric_type = "ALBRequestCountPerTarget"
  target_tracking_resource_label         = "${module.edge.alb_arn_suffix}/${module.edge.target_group_arn_suffix}"
  target_tracking_target_value           = var.frontend_target_tracking_request_count

  tags = local.common_tags
}

# 7. Backend — ASG nas sub-redes privadas 3/4, sem tráfego direto de entrada,
#    consome a fila e acessa o DynamoDB (docs/flowqueue.md seção 2.5).
#    A lógica de idempotência (consulta DynamoDB antes do S3, DeleteMessage
#    só após gravação confirmada) é responsabilidade do código do Backend —
#    ver ../docs/backend-idempotencia.md para o contrato esperado.
module "backend" {
  source = "./modules/compute"

  name             = "${local.name}-backend"
  vpc_id           = module.network.vpc_id
  subnet_ids       = module.network.private_backend_subnet_ids
  ami_id           = var.backend_ami_id
  instance_type    = var.instance_type
  min_size         = var.backend_min_size
  max_size         = var.backend_max_size
  desired_capacity = var.backend_desired_capacity

  ingress_rules = []

  extra_policy_statements = [
    {
      Effect   = "Allow"
      Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
      Resource = module.messaging.main_queue_arn
    },
    {
      Effect = "Allow"
      Action = [
        "dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem",
        "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:Scan"
      ]
      Resource = module.database.table_arn
    },
    {
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
      Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${local.name}/*"
    },
    {
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:GetObjectRetention"]
      Resource = "${module.storage.bucket_arn}/*"
    },
    {
      Effect   = "Allow"
      Action   = ["s3:ListBucket"]
      Resource = module.storage.bucket_arn
    }
  ]

  # Step scaling por backlog da fila principal — as policies em si ficam
  # aqui, o alarme do CloudWatch que as aciona está em module.observability
  # (docs/melhorias.md item 5).
  enable_step_scaling = true

  tags = local.common_tags
}

# 8. Observabilidade — alarmes CloudWatch (backlog da fila, DLQ, ALB) e o
#    tópico SNS que os notifica; também aciona o step scaling do Backend
#    acima (docs/melhorias.md item 5)
module "observability" {
  source = "./modules/observability"

  name        = local.name
  alarm_email = var.alarm_email

  main_queue_name = module.messaging.main_queue_name
  dlq_name        = module.messaging.dlq_name

  backend_scale_out_policy_arn = module.backend.step_scale_out_policy_arn
  backend_scale_in_policy_arn  = module.backend.step_scale_in_policy_arn

  alb_arn_suffix = module.edge.alb_arn_suffix

  tags = local.common_tags
}
