variable "name" {
  description = "Prefixo usado no nome do Web ACL"
  type        = string
}

variable "tags" {
  description = "Tags comuns aplicadas aos recursos do módulo"
  type        = map(string)
  default     = {}
}
