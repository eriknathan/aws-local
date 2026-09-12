# Amazon DynamoDB — fonte de verdade dos dados da aplicação, consultada e
# atualizada pelas instâncias de Backend (docs/flowqueue.md seção 2.6).
resource "aws_dynamodb_table" "this" {
  name         = var.table_name
  billing_mode = var.billing_mode
  hash_key     = var.hash_key

  attribute {
    name = var.hash_key
    type = var.hash_key_type
  }

  tags = merge(var.tags, { Name = var.table_name })
}
