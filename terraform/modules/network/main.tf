resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${var.name}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-igw" })
}

# Sub-redes públicas (uma por AZ) — hospedam os NAT Gateways
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  availability_zone       = var.azs[count.index]
  cidr_block              = var.public_subnet_cidrs[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, { Name = "${var.name}-public-${count.index + 1}" })
}

# Sub-redes privadas de Frontend (sub-rede privada 1 = AZ A, 2 = AZ B)
resource "aws_subnet" "private_frontend" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  availability_zone = var.azs[count.index]
  cidr_block        = var.private_frontend_subnet_cidrs[count.index]

  tags = merge(var.tags, { Name = "${var.name}-private-frontend-${count.index + 1}" })
}

# Sub-redes privadas de Backend (sub-rede privada 3 = AZ A, 4 = AZ B)
resource "aws_subnet" "private_backend" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  availability_zone = var.azs[count.index]
  cidr_block        = var.private_backend_subnet_cidrs[count.index]

  tags = merge(var.tags, { Name = "${var.name}-private-backend-${count.index + 1}" })
}

# Um NAT Gateway por AZ
resource "aws_eip" "nat" {
  count  = 2
  domain = "vpc"

  tags = merge(var.tags, { Name = "${var.name}-nat-eip-${count.index + 1}" })
}

resource "aws_nat_gateway" "this" {
  count         = 2
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.tags, { Name = "${var.name}-nat-${count.index + 1}" })

  depends_on = [aws_internet_gateway.this]
}

# Rota pública -> Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, { Name = "${var.name}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Uma rota privada por AZ -> NAT Gateway da própria AZ
# (compartilhada pelas sub-redes de frontend e backend daquela AZ)
resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[count.index].id
  }

  tags = merge(var.tags, { Name = "${var.name}-private-rt-${count.index + 1}" })
}

resource "aws_route_table_association" "private_frontend" {
  count          = 2
  subnet_id      = aws_subnet.private_frontend[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table_association" "private_backend" {
  count          = 2
  subnet_id      = aws_subnet.private_backend[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# --- VPC Endpoints (docs/melhorias.md item 4) ---

# Gateway endpoints (S3 e DynamoDB) — sem custo por hora, associados às
# route tables privadas já existentes. Sem isso, tráfego de Frontend/Backend
# pro S3/DynamoDB sai pelo NAT Gateway mesmo sendo tráfego só dentro da AWS.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(var.tags, { Name = "${var.name}-s3-endpoint" })
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(var.tags, { Name = "${var.name}-dynamodb-endpoint" })
}

# Security group compartilhado pelos Interface endpoints — libera 443 só a
# partir da própria VPC.
resource "aws_security_group" "interface_endpoints" {
  name_prefix = "${var.name}-vpce-"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS a partir da VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-vpce-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# Interface endpoints (SQS, SSM, SSM Messages, EC2 Messages) — os três
# últimos juntos são o pré-requisito pro Session Manager funcionar sem NAT
# Gateway. ENIs ficam nas sub-redes privadas de Backend (uma por AZ); as
# sub-redes de Frontend alcançam via roteamento local da VPC (mesma VPC,
# sem passar por NAT/IGW).
locals {
  interface_endpoint_services = ["sqs", "ssm", "ssmmessages", "ec2messages"]
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_endpoint_services)

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private_backend[*].id
  security_group_ids  = [aws_security_group.interface_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name}-${each.value}-endpoint" })
}
