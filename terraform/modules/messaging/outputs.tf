output "main_queue_id" {
  value = aws_sqs_queue.main.id
}

output "main_queue_url" {
  value = aws_sqs_queue.main.url
}

output "main_queue_arn" {
  value = aws_sqs_queue.main.arn
}

output "main_queue_name" {
  value = aws_sqs_queue.main.name
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}

output "dlq_arn" {
  value = aws_sqs_queue.dlq.arn
}

output "dlq_name" {
  value = aws_sqs_queue.dlq.name
}
