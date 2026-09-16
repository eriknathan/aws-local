variable "project_name" {
  description = "Prefixo usado no nome de todos os recursos"
  type        = string
  default     = "flowqueue"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "tags" {
  description = "Tags comuns aplicadas a todos os recursos"
  type        = map(string)
  default     = { Project = "flowqueue" }
}

# --- Alvo: Floci local vs. AWS real ---

variable "use_local_endpoint" {
  description = "true = usa o Floci local (endpoint único); false = AWS real"
  type        = bool
  default     = true
}

variable "aws_endpoint_url" {
  description = "Endpoint do Floci quando use_local_endpoint = true"
  type        = string
  default     = "http://localhost:4566"
}

variable "aws_access_key" {
  description = "Access key. Qualquer valor não vazio serve para o Floci."
  type        = string
  default     = "test"
}

variable "aws_secret_key" {
  description = "Secret key. Qualquer valor não vazio serve para o Floci."
  type        = string
  default     = "test"
  sensitive   = true
}

# --- Rede ---

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  description = "As duas Zonas de Disponibilidade usadas (AZ A e AZ B)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

# --- Compute ---

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "frontend_ami_id" {
  description = "AMI usada nas instâncias de Frontend. AJUSTE conforme o mapeamento de imagens do Floci (ver ../docs/floci.md, seção 2.3) antes do apply do módulo compute."
  type        = string
  default     = "ami-0000000000000front"
}

variable "backend_ami_id" {
  description = "AMI usada nas instâncias de Backend. AJUSTE conforme o mapeamento de imagens do Floci (ver ../docs/floci.md, seção 2.3) antes do apply do módulo compute."
  type        = string
  default     = "ami-0000000000000back"
}

variable "frontend_min_size" {
  type    = number
  default = 2
}

variable "frontend_max_size" {
  type    = number
  default = 4
}

variable "frontend_desired_capacity" {
  type    = number
  default = 2
}

variable "backend_min_size" {
  type    = number
  default = 2
}

variable "backend_max_size" {
  type    = number
  default = 4
}

variable "backend_desired_capacity" {
  type    = number
  default = 2
}

# --- Mensageria ---

variable "sqs_max_receive_count" {
  description = "Tentativas de processamento antes de mover a mensagem para a DLQ"
  type        = number
  default     = 5
}

variable "sqs_visibility_timeout_seconds" {
  description = "Tempo em que uma mensagem fica invisível após ser consumida pelo Backend. Precisa ficar acima do pior caso de tempo de processamento (consulta ao DynamoDB + upload no S3 + gravação condicional), senão a mensagem reaparece e é reprocessada antes da confirmação (ver ../docs/backend-idempotencia.md)."
  type        = number
  default     = 90
}

# --- Borda ---

variable "enable_cloudfront" {
  description = "Se false, cria só o ALB (sem CloudFront na frente) — útil caso o Floci não simule bem o CloudFront."
  type        = bool
  default     = true
}

variable "enable_alb_listener" {
  description = "Se false, não cria o listener HTTP do ALB — útil enquanto o CreateListener do Floci estiver com bug (ver terraform/README.md)."
  type        = bool
  default     = true
}

# --- Armazenamento (recibos de pedido) ---

variable "receipts_retention_days" {
  description = "Retenção mínima (S3 Object Lock) dos recibos de pedido, em dias"
  type        = number
  default     = 365
}

variable "receipts_retention_mode" {
  description = "Modo do Object Lock dos recibos: COMPLIANCE ou GOVERNANCE"
  type        = string
  default     = "COMPLIANCE"
}

# --- Scaling e observabilidade ---

variable "frontend_target_tracking_request_count" {
  description = "Alvo de ALBRequestCountPerTarget pro target tracking do Frontend (requisições por instância por minuto)"
  type        = number
  default     = 750
}

variable "alarm_email" {
  description = "E-mail a inscrever no tópico SNS de alarmes. null = tópico criado sem inscrição (inscreva depois sem precisar mudar Terraform)."
  type        = string
  default     = null
}

# --- HTTPS / WAF (docs/melhorias.md item 3) ---

variable "domain_name" {
  description = "Hostname usado pro certificado ACM e pro DNS do FlowQueue (ex.: flowqueue.eriknathan.me). null = item 3 fica desligado (ALB/CloudFront seguem em HTTP puro, único modo testável hoje contra o Floci). O domínio precisa ter validação DNS feita manualmente fora do Terraform — ver ../docs/dns-validacao.md."
  type        = string
  default     = null
}
