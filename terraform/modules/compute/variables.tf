variable "name" {
  description = "Prefixo usado no nome dos recursos (ex.: flowqueue-frontend)"
  type        = string
}

variable "vpc_id" {
  description = "ID da VPC"
  type        = string
}

variable "subnet_ids" {
  description = "IDs das sub-redes (uma por AZ) onde o Auto Scaling Group lança instâncias"
  type        = list(string)
}

variable "ami_id" {
  description = "AMI usada nas instâncias EC2"
  type        = string
}

variable "instance_type" {
  description = "Tipo de instância EC2"
  type        = string
  default     = "t3.micro"
}

variable "min_size" {
  type    = number
  default = 2
}

variable "max_size" {
  type    = number
  default = 4
}

variable "desired_capacity" {
  type    = number
  default = 2
}

variable "ingress_rules" {
  description = "Regras de entrada do security group das instâncias"
  type = list(object({
    from_port       = number
    to_port         = number
    protocol        = string
    cidr_blocks     = optional(list(string))
    security_groups = optional(list(string))
  }))
  default = []
}

variable "target_group_arns" {
  description = "ARNs de target groups do ALB para anexar ao ASG (vazio para o Backend, que não recebe tráfego direto)"
  type        = list(string)
  default     = []
}

variable "extra_policy_statements" {
  description = "Statements IAM extras (lista de objetos no formato de uma policy JSON) anexados à role da instância, além do AmazonSSMManagedInstanceCore"
  type        = list(any)
  default     = []
}

variable "user_data" {
  description = "User data (script) executado na inicialização da instância"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags comuns aplicadas aos recursos do módulo"
  type        = map(string)
  default     = {}
}

# --- Scaling (docs/melhorias.md item 5) ---

variable "enable_target_tracking_scaling" {
  description = "Se true, cria uma aws_autoscaling_policy do tipo TargetTrackingScaling (ex.: Frontend em ALBRequestCountPerTarget)"
  type        = bool
  default     = false
}

variable "target_tracking_predefined_metric_type" {
  description = "Métrica pré-definida do target tracking (ex.: ALBRequestCountPerTarget). Obrigatório quando enable_target_tracking_scaling = true."
  type        = string
  default     = null
}

variable "target_tracking_resource_label" {
  description = "resource_label exigido por métricas por-recurso (ex.: ALBRequestCountPerTarget), formato app/<lb-name>/<lb-id>/targetgroup/<tg-name>/<tg-id>"
  type        = string
  default     = null
}

variable "target_tracking_target_value" {
  description = "Valor alvo da métrica de target tracking. Obrigatório quando enable_target_tracking_scaling = true."
  type        = number
  default     = null
}

variable "enable_step_scaling" {
  description = "Se true, cria duas aws_autoscaling_policy do tipo StepScaling (scale-out e scale-in). As policies não têm alarme próprio — algo externo (ex.: modules/observability) precisa acioná-las via alarm_actions."
  type        = bool
  default     = false
}

variable "step_scaling_out_adjustment" {
  description = "Quantas instâncias adicionar quando a policy de scale-out for acionada"
  type        = number
  default     = 1
}

variable "step_scaling_in_adjustment" {
  description = "Quantas instâncias remover quando a policy de scale-in for acionada (número negativo)"
  type        = number
  default     = -1
}

variable "step_scaling_warmup_seconds" {
  description = "Tempo estimado pra uma instância nova ficar pronta — usado como estimated_instance_warmup das policies de scaling"
  type        = number
  default     = 60
}
