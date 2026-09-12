variable "parameters" {
  description = "Mapa de parâmetros a criar no SSM Parameter Store: { nome => { value, type } }"
  type = map(object({
    value = string
    type  = string # String | StringList | SecureString
  }))
  default = {}
}

variable "tags" {
  description = "Tags comuns aplicadas aos recursos do módulo"
  type        = map(string)
  default     = {}
}
