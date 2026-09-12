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
