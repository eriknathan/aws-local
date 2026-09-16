variable "name" {
  description = "Prefixo usado no nome dos recursos"
  type        = string
}

variable "alarm_email" {
  description = "E-mail a inscrever no tópico SNS de alarmes. null = tópico criado sem inscrição (inscreva depois via console/CLI, sem precisar mudar Terraform)."
  type        = string
  default     = null
}

# --- Fila principal e DLQ ---

variable "main_queue_name" {
  description = "Nome (não ARN) da fila principal — dimensão QueueName dos alarmes de SQS"
  type        = string
}

variable "dlq_name" {
  description = "Nome (não ARN) da DLQ — dimensão QueueName do alarme de DLQ não vazia"
  type        = string
}

variable "backend_scale_out_policy_arn" {
  description = "ARN da aws_autoscaling_policy de scale-out do Backend (StepScaling)"
  type        = string
}

variable "backend_scale_in_policy_arn" {
  description = "ARN da aws_autoscaling_policy de scale-in do Backend (StepScaling)"
  type        = string
}

variable "queue_backlog_scale_out_threshold" {
  description = "ApproximateNumberOfMessagesVisible acima disso aciona scale-out do Backend"
  type        = number
  default     = 20
}

variable "queue_backlog_scale_in_threshold" {
  description = "ApproximateNumberOfMessagesVisible abaixo disso aciona scale-in do Backend"
  type        = number
  default     = 5
}

variable "queue_oldest_message_age_threshold_seconds" {
  description = "ApproximateAgeOfOldestMessage (segundos) acima disso dispara alarme — backlog crescendo mais rápido que o processamento"
  type        = number
  default     = 300
}

# --- ALB ---

variable "alb_arn_suffix" {
  description = "arn_suffix do ALB (module.edge.alb_arn_suffix) — dimensão LoadBalancer dos alarmes"
  type        = string
}

variable "alb_5xx_threshold" {
  description = "Soma de HTTPCode_Target_5XX_Count no período acima disso dispara alarme"
  type        = number
  default     = 10
}

variable "alb_latency_threshold_seconds" {
  description = "TargetResponseTime médio (segundos) acima disso dispara alarme"
  type        = number
  default     = 1
}

# --- Avaliação ---

variable "period_seconds" {
  description = "Período de avaliação dos alarmes, em segundos"
  type        = number
  default     = 60
}

variable "evaluation_periods" {
  description = "Quantos períodos consecutivos violando o threshold antes de disparar (exceto DLQ, que dispara com 1)"
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags comuns aplicadas aos recursos do módulo"
  type        = map(string)
  default     = {}
}
