# Dead Letter Queue — recebe mensagens que falharam repetidamente no
# processamento (ver docs/flowqueue.md seção 2.4).
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name}-dlq"
  message_retention_seconds = var.dlq_message_retention_seconds

  tags = merge(var.tags, { Name = "${var.name}-dlq" })
}

# Fila principal — recebe as mensagens do Frontend e é consumida pelo Backend.
resource "aws_sqs_queue" "main" {
  name                       = "${var.name}-main"
  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = merge(var.tags, { Name = "${var.name}-main" })
}
