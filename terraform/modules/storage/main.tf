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

# Defesa em profundidade pra retenção mínima: o IAM do Backend já não tem
# PutObjectRetention/BypassGovernanceRetention (ver módulo compute), mas essa
# bucket policy nega essas ações pra qualquer principal, mesmo que um papel
# futuro ganhe essa permissão por engano. Também trava o modo do Object Lock
# em var.retention_mode — impede downgrade de COMPLIANCE pra GOVERNANCE (ou
# vice-versa) via header no PutObject.
#
# Limitação conhecida: não dá pra expressar "mínimo de var.retention_days
# dias" como condição estática de bucket policy — a data-alvo é relativa a
# "agora" e a AWS não tem uma condition key pra isso. O prazo em si depende
# do default_retention configurado em aws_s3_bucket_object_lock_configuration
# acima; esta policy só impede enfraquecer o modo/bypassar a retenção.
#
# Nota: se var.retention_mode = "GOVERNANCE", negar BypassGovernanceRetention
# incondicionalmente também bloqueia o uso legítimo desse modo (que existe
# justamente para permitir bypass com permissão especial). Com o default
# COMPLIANCE não há esse conflito.
resource "aws_s3_bucket_policy" "receipts" {
  bucket = aws_s3_bucket.receipts.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyRetentionBypass"
        Effect    = "Deny"
        Principal = "*"
        Action = [
          "s3:PutObjectRetention",
          "s3:BypassGovernanceRetention",
        ]
        Resource = "${aws_s3_bucket.receipts.arn}/*"
      },
      {
        Sid       = "DenyObjectLockModeDowngrade"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.receipts.arn}/*"
        Condition = {
          StringNotEqualsIfExists = {
            "s3:object-lock-mode" = var.retention_mode
          }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_object_lock_configuration.receipts]
}
