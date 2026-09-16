variable "name" {
  description = "Prefixo usado no nome dos recursos"
  type        = string
}

variable "vpc_id" {
  description = "ID da VPC onde o ALB será criado"
  type        = string
}

variable "public_subnet_ids" {
  description = "IDs das sub-redes públicas (uma por AZ) onde o ALB será colocado"
  type        = list(string)
}

variable "target_port" {
  description = "Porta em que as instâncias de Frontend escutam"
  type        = number
  default     = 80
}

variable "health_check_path" {
  description = "Caminho usado pelo health check do target group"
  type        = string
  default     = "/"
}

variable "enable_cloudfront" {
  description = "Se true, cria uma distribution CloudFront na frente do ALB"
  type        = bool
  default     = true
}

variable "enable_listener" {
  description = "Se true, cria o listener HTTP do ALB (ver nota sobre bug do Floci em main.tf)"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags comuns aplicadas aos recursos do módulo"
  type        = map(string)
  default     = {}
}

# --- HTTPS / WAF (docs/melhorias.md item 3) ---

variable "enable_https" {
  description = "Se true, cria o listener HTTPS (443) com var.acm_certificate_arn, e o listener HTTP (80) vira redirect 301 pra HTTPS em vez de forward direto"
  type        = bool
  default     = false
}

variable "acm_certificate_arn" {
  description = "ARN do certificado ACM regional (mesma região do ALB), já validado. Obrigatório quando enable_https = true."
  type        = string
  default     = null
}

variable "acm_certificate_arn_cloudfront" {
  description = "ARN do certificado ACM em us-east-1, já validado. Obrigatório quando enable_https && enable_cloudfront."
  type        = string
  default     = null
}

variable "origin_secret_header_value" {
  description = "Valor de um header secreto que o CloudFront envia ao ALB e o ALB exige pra encaminhar tráfego — restringe o ALB a só aceitar requisições vindas do CloudFront. Usado (e obrigatório) só quando enable_https && enable_cloudfront."
  type        = string
  default     = null
  sensitive   = true
}

variable "waf_web_acl_arn" {
  description = "ARN do Web ACL (scope CLOUDFRONT) a associar à distribution. null = sem WAF."
  type        = string
  default     = null
}
