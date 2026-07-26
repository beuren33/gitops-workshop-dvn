variable "project" {
  description = "Prefixo de nomenclatura do projeto, usado em nomes de recursos e tags (ex.: \"dvn\")."
  type        = string
  nullable    = false
}

variable "environment" {
  description = "Nome do ambiente, usado em nomes de recursos e tags (ex.: \"dev\")."
  type        = string
  nullable    = false
}

variable "vpc_cidr_block" {
  description = "Bloco CIDR IPv4 primário da VPC (ex.: \"10.0.0.0/26\"). Definitivo após a criação: não pode ser alterado nem removido, apenas acrescido de CIDRs secundários."
  type        = string
  nullable    = false
}

variable "subnet_newbits" {
  description = "Bits adicionais em relação ao CIDR da VPC usados por cidrsubnet() para calcular o tamanho de cada subnet (ex.: 2 transforma um /26 em blocos /28). As subnets nunca têm o CIDR escrito literalmente."
  type        = number
  nullable    = false
}

variable "az_count" {
  description = "Quantidade de Availability Zones a utilizar, resolvidas via data source aws_availability_zones em ordem determinística (nunca hardcoded). Cria 1 subnet pública e 1 subnet privada por AZ."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "az_count deve ser >= 2: o desenho depende de 2 subnets públicas e 2 privadas em AZs distintas para viabilizar ALB e DB subnet group do RDS."
  }
}
