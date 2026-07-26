variable "aws_region" {
  description = "Região AWS onde os recursos de rede serão provisionados."
  type        = string
  default     = "us-east-1"
  nullable    = false
}

variable "project" {
  description = "Prefixo de nomenclatura do projeto, usado em nomes de recursos e tags."
  type        = string
  default     = "dvn"
  nullable    = false
}

variable "environment" {
  description = "Nome do ambiente, usado em nomes de recursos e tags."
  type        = string
  default     = "dev"
  nullable    = false
}

variable "owner" {
  description = "Responsável pelo ambiente, usado na tag Owner para atribuição de custo e contato."
  type        = string
  nullable    = false
}

variable "cost_center" {
  description = "Centro de custo usado na tag CostCenter para atribuição de despesa."
  type        = string
  nullable    = false
}

variable "vpc_cidr_block" {
  description = "Bloco CIDR IPv4 primário da VPC. Definitivo após a criação (ADR-001, ressalva 1.1)."
  type        = string
  default     = "10.0.0.0/26"
  nullable    = false
}

variable "subnet_newbits" {
  description = "Bits adicionais em relação ao CIDR da VPC para calcular o tamanho das subnets. 2 transforma o /26 em quatro /28 (ADR-001, Seção 3)."
  type        = number
  default     = 2
  nullable    = false
}

variable "az_count" {
  description = "Quantidade de Availability Zones a utilizar, resolvidas via data source (ADR-001, revisão 3: 2 AZs)."
  type        = number
  default     = 2
  nullable    = false
}
