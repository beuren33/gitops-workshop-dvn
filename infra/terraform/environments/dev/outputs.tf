output "vpc_id" {
  description = "ID da VPC do ambiente dev."
  value       = module.network.vpc_id
}

output "vpc_cidr_block" {
  description = "Bloco CIDR IPv4 primário da VPC do ambiente dev."
  value       = module.network.vpc_cidr_block
}

output "public_subnet_ids" {
  description = "Lista de IDs das subnets públicas do ambiente dev (consumível por subnet_ids de ALB)."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Lista de IDs das subnets privadas do ambiente dev (consumível por DB subnet group do RDS)."
  value       = module.network.private_subnet_ids
}

output "public_route_table_id" {
  description = "ID da route table pública do ambiente dev."
  value       = module.network.public_route_table_id
}

output "private_route_table_id" {
  description = "ID da route table privada do ambiente dev."
  value       = module.network.private_route_table_id
}

output "internet_gateway_id" {
  description = "ID do Internet Gateway do ambiente dev."
  value       = module.network.internet_gateway_id
}

output "nat_gateway_id" {
  description = "ID do NAT Gateway único do ambiente dev."
  value       = module.network.nat_gateway_id
}

output "nat_gateway_public_ip" {
  description = "Endereço IP público do NAT Gateway do ambiente dev."
  value       = module.network.nat_gateway_public_ip
}

output "availability_zones" {
  description = "Availability Zones utilizadas pelo ambiente dev, na ordem az-a, az-b."
  value       = module.network.availability_zones
}
