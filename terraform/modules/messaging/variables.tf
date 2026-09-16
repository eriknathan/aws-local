variable "name" {
  description = "Prefixo usado no nome das filas"
  type        = string
}

variable "visibility_timeout_seconds" {
  description = "Tempo em que uma mensagem fica invisível após ser consumida pelo Backend"
  type        = number
  default     = 90
}

variable "message_retention_seconds" {
  description = "Tempo de retenção das mensagens na fila principal"
  type        = number
  default     = 345600 # 4 dias
}

variable "dlq_message_retention_seconds" {
  description = "Tempo de retenção das mensagens na DLQ (maior, para dar tempo de investigar falhas)"
  type        = number
  default     = 1209600 # 14 dias (máximo do SQS)
}

variable "max_receive_count" {
  description = "Quantas tentativas de processamento antes de mover a mensagem para a DLQ"
  type        = number
  default     = 5
}

variable "tags" {
  description = "Tags comuns aplicadas aos recursos do módulo"
  type        = map(string)
  default     = {}
}
