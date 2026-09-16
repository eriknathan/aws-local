variable "name" {
  description = "Prefixo usado no nome do bucket"
  type        = string
}

variable "retention_days" {
  description = "Dias mínimos de retenção dos recibos (S3 Object Lock)"
  type        = number
  default     = 365
}

variable "retention_mode" {
  description = "Modo do Object Lock: COMPLIANCE (ninguém apaga antes do prazo, nem o root) ou GOVERNANCE (pode ser sobrescrito com permissão especial)"
  type        = string
  default     = "COMPLIANCE"

  validation {
    condition     = contains(["COMPLIANCE", "GOVERNANCE"], var.retention_mode)
    error_message = "retention_mode deve ser COMPLIANCE ou GOVERNANCE."
  }
}

variable "tags" {
  description = "Tags comuns aplicadas aos recursos do módulo"
  type        = map(string)
  default     = {}
}
