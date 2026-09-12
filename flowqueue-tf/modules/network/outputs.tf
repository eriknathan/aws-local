output "vpc_id" {
  value = aws_vpc.this.id
}

output "azs" {
  value = var.azs
}

output "internet_gateway_id" {
  value = aws_internet_gateway.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_frontend_subnet_ids" {
  value = aws_subnet.private_frontend[*].id
}

output "private_backend_subnet_ids" {
  value = aws_subnet.private_backend[*].id
}

output "nat_gateway_ids" {
  value = aws_nat_gateway.this[*].id
}
