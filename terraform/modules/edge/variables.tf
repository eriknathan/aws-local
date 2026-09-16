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
