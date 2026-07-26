terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.56"
    }
  }

  # Backend REMOTO S3 com lock nativo do S3 (use_lockfile), adotado na
  # revisão 4 do ADR-001 (Seção 4 "Decisão de backend (revisão 4)" e Anexo
  # A.1, Etapa 0). Bucket "gitops-terraformcode33" (us-east-1) já existe e
  # não é gerenciado por este Terraform (ver A.4). use_lockfile requer
  # Terraform >= 1.10.0 — satisfeito pela restrição "~> 1.15" acima.
  backend "s3" {
    bucket       = "gitops-terraformcode33"
    key          = "network/dev/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}
