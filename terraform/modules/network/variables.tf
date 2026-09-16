variable "name" {
  description = "Prefixo usado no nome dos recursos (ex.: flowqueue)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block da VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Zonas de disponibilidade usadas (exatamente 2: AZ A e AZ B)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition     = length(var.azs) == 2
    error_message = "A arquitetura FlowQueue espera exatamente 2 AZs."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDRs das sub-redes públicas (uma por AZ, para NAT Gateway)"
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_frontend_subnet_cidrs" {
  description = "CIDRs das sub-redes privadas de frontend (sub-redes privadas 1 e 2)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "private_backend_subnet_cidrs" {
  description = "CIDRs das sub-redes privadas de backend (sub-redes privadas 3 e 4)"
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.21.0/24"]
}

variable "tags" {
  description = "Tags comuns aplicadas a todos os recursos do módulo"
  type        = map(string)
  default     = {}
}

variable "aws_region" {
  description = "Região usada para montar o service_name dos VPC endpoints (ex.: com.amazonaws.<região>.s3)"
  type        = string
}
