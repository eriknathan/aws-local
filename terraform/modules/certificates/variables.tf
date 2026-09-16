variable "domain_name" {
  description = "Hostname pro certificado (ex.: flowqueue.eriknathan.me)"
  type        = string
}

variable "create_cloudfront_certificate" {
  description = "Se true, também cria (via provider alias us_east_1) o certificado obrigatório pro CloudFront — que precisa existir em us-east-1 independente da região principal"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags comuns aplicadas aos recursos do módulo"
  type        = map(string)
  default     = {}
}
