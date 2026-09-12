# Nomes de bucket S3 são globalmente únicos — sufixo aleatório evita colisão
# ao reaplicar em outra conta/região (ex.: quando migrar pra AWS real).
resource "random_id" "suffix" {
  byte_length = 4
}

# Bucket dos recibos de pedido gerados pelo Backend. Object Lock precisa ser
# habilitado na criação do bucket (não dá pra ligar depois).
resource "aws_s3_bucket" "receipts" {
  bucket              = "${var.name}-receipts-${random_id.suffix.hex}"
  object_lock_enabled = true

  tags = merge(var.tags, { Name = "${var.name}-receipts" })
}

# Object Lock exige versionamento habilitado.
resource "aws_s3_bucket_versioning" "receipts" {
  bucket = aws_s3_bucket.receipts.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Retenção mínima de var.retention_days (default 365) — em modo COMPLIANCE,
# nem o dono da conta consegue apagar/sobrescrever um objeto antes do prazo.
resource "aws_s3_bucket_object_lock_configuration" "receipts" {
  bucket = aws_s3_bucket.receipts.id

  rule {
    default_retention {
      mode = var.retention_mode
      days = var.retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.receipts]
}

resource "aws_s3_bucket_public_access_block" "receipts" {
  bucket = aws_s3_bucket.receipts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "receipts" {
  bucket = aws_s3_bucket.receipts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
