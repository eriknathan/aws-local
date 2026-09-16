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
