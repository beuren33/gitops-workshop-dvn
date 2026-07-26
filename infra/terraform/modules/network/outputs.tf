output "vpc_id" {
  description = "ID da VPC criada."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "Bloco CIDR IPv4 primário da VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Lista de IDs das subnets públicas, uma por AZ, em ordem determinística (consumível por subnet_ids de ALB)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Lista de IDs das subnets privadas, uma por AZ, em ordem determinística (consumível por DB subnet group do RDS)."
  value       = aws_subnet.private[*].id
}

output "public_route_table_id" {
  description = "ID da route table pública, associada às subnets públicas."
  value       = aws_route_table.public.id
}

output "private_route_table_id" {
  description = "ID da route table privada, associada às subnets privadas."
  value       = aws_route_table.private.id
}

output "internet_gateway_id" {
  description = "ID do Internet Gateway anexado à VPC."
  value       = aws_internet_gateway.this.id
}

output "nat_gateway_id" {
  description = "ID do NAT Gateway único, provisionado na subnet pública da AZ-a."
  value       = aws_nat_gateway.this.id
}

output "nat_gateway_public_ip" {
  description = "Endereço IP público (Elastic IP) associado ao NAT Gateway."
  value       = aws_nat_gateway.this.public_ip
}

output "availability_zones" {
  description = "Lista das Availability Zones utilizadas, na mesma ordem dos índices das subnets (az-a, az-b, ...)."
  value       = local.azs
}
