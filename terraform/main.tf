locals {
  name        = var.project_name
  common_tags = merge(var.tags, { ManagedBy = "terraform" })
}

# 1. Rede — VPC, IGW, sub-redes públicas/frontend/backend, NAT Gateways
#    (docs/flowqueue.md seções 2.1, 2.2, 2.3, 2.5)
module "network" {
  source = "./modules/network"

  name     = local.name
  vpc_cidr = var.vpc_cidr
  azs      = var.azs
  tags     = local.common_tags
}

# 2. Mensageria — fila principal + DLQ (docs/flowqueue.md seção 2.4)
module "messaging" {
  source = "./modules/messaging"

  name              = local.name
  max_receive_count = var.sqs_max_receive_count
  tags              = local.common_tags
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

# 4. Operação — Parameter Store com config derivada de outros módulos
#    (docs/flowqueue.md seção 2.7)
module "parameters" {
  source = "./modules/parameters"

  parameters = {
    "/${local.name}/queue/main-url"          = { value = module.messaging.main_queue_url, type = "String" }
    "/${local.name}/queue/dlq-url"           = { value = module.messaging.dlq_url, type = "String" }
    "/${local.name}/database/table-name"     = { value = module.database.table_name, type = "String" }
    "/${local.name}/storage/receipts-bucket" = { value = module.storage.bucket_name, type = "String" }
  }

  tags = local.common_tags
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
    }
  ]

  tags = local.common_tags
}

# 7. Backend — ASG nas sub-redes privadas 3/4, sem tráfego direto de entrada,
#    consome a fila e acessa o DynamoDB (docs/flowqueue.md seção 2.5)
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

  tags = local.common_tags
}
