variable "table_name" {
  description = "Nome da tabela DynamoDB"
  type        = string
}

variable "billing_mode" {
  description = "Modo de cobrança da tabela (PAY_PER_REQUEST = serverless, sem gerenciar capacidade)"
  type        = string
  default     = "PAY_PER_REQUEST"
}

variable "hash_key" {
  description = "Nome do atributo usado como chave primária (partition key)"
  type        = string
  default     = "id"
}

variable "hash_key_type" {
  description = "Tipo do atributo de partition key (S, N ou B)"
  type        = string
  default     = "S"
}

variable "tags" {
  description = "Tags comuns aplicadas aos recursos do módulo"
  type        = map(string)
  default     = {}
}
