output "vpc_id" {
  value = module.network.vpc_id
}

output "alb_dns_name" {
  value = module.edge.alb_dns_name
}

output "cloudfront_domain_name" {
  value = module.edge.cloudfront_domain_name
}

output "sqs_main_queue_url" {
  value = module.messaging.main_queue_url
}

output "sqs_dlq_url" {
  value = module.messaging.dlq_url
}

output "dynamodb_table_name" {
  value = module.database.table_name
}

output "receipts_bucket_name" {
  value = module.storage.bucket_name
}

output "frontend_asg_name" {
  value = module.frontend.asg_name
}

output "backend_asg_name" {
  value = module.backend.asg_name
}
