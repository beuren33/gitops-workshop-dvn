# Composição do ambiente "dev" — provider e chamada do módulo de rede.
# Implementa o Anexo A do ADR-001 (docs/ADR-001-arquitetura-de-rede-vpc-base-aws.md).
# State REMOTO em backend S3 com lock nativo do S3 (ver versions.tf,
# bloco "backend"; ADR-001 Seção 4, revisão 4, e Anexo A.1 Etapa 0).

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner
      CostCenter  = var.cost_center
    }
  }
}

module "network" {
  source = "../../modules/network"

  project        = var.project
  environment    = var.environment
  vpc_cidr_block = var.vpc_cidr_block
  subnet_newbits = var.subnet_newbits
  az_count       = var.az_count
}
