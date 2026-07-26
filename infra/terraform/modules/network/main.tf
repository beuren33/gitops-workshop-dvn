# Módulo de rede base (VPC, subnets públicas/privadas, Internet Gateway,
# NAT Gateway único e roteamento) — implementa a Opção A do ADR-001
# (docs/ADR-001-arquitetura-de-rede-vpc-base-aws.md).

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # "az-a", "az-b", ... referem-se ao índice da AZ resolvida pelo data
  # source, nunca ao literal us-east-1a/us-east-1b (ADR-001, Seção A.2).
  az_labels = ["a", "b", "c", "d", "e", "f", "g", "h"]
  azs       = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # CIDRs derivados do CIDR da VPC via cidrsubnet(), nunca escritos
  # literalmente (ADR-001, A.3.4). Com vpc_cidr_block = 10.0.0.0/26 e
  # subnet_newbits = 2: público-a 10.0.0.0/28, público-b 10.0.0.16/28,
  # privado-a 10.0.0.32/28, privado-b 10.0.0.48/28.
  public_subnet_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr_block, var.subnet_newbits, i)]
  private_subnet_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr_block, var.subnet_newbits, i + var.az_count)]
}

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr_block

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project}-${var.environment}-vpc"
  }
}

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project}-${var.environment}-public-subnet-${local.az_labels[count.index]}"
  }
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.private_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project}-${var.environment}-private-subnet-${local.az_labels[count.index]}"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project}-${var.environment}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.project}-${var.environment}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Elastic IP do NAT Gateway único (Opção A do ADR-001). Depende
# explicitamente do Internet Gateway, conforme recomendação da
# documentação do provider.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project}-${var.environment}-nat-eip-a"
  }

  depends_on = [aws_internet_gateway.this]
}

# NAT Gateway único, na subnet pública da AZ-a (índice 0), servindo as
# duas subnets privadas. A AZ nunca é hardcoded: o índice 0 sempre
# corresponde à primeira AZ resolvida pelo data source (ADR-001, Seção 6,
# risco "NAT Gateway criado antes do Internet Gateway estar anexado").
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.project}-${var.environment}-nat-a"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name = "${var.project}-${var.environment}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
