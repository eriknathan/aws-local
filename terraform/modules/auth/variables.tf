variable "name" {
  description = "Prefixo usado no nome do User Pool e do app client"
  type        = string
}

variable "password_minimum_length" {
  description = "Tamanho mínimo de senha exigido pelo User Pool"
  type        = number
  default     = 8
}

variable "mfa_configuration" {
  description = "OFF, ON ou OPTIONAL"
  type        = string
  default     = "OFF"
}

variable "tags" {
  description = "Tags comuns aplicadas aos recursos do módulo"
  type        = map(string)
  default     = {}
}
