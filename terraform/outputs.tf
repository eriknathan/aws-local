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

output "alarms_sns_topic_arn" {
  value = module.observability.sns_topic_arn
}

output "cognito_user_pool_id" {
  value = module.auth.user_pool_id
}

output "cognito_user_pool_client_id" {
  value = module.auth.user_pool_client_id
}

output "acm_dns_validation_records" {
  description = "Registros DNS a criar manualmente no provedor (Hostinger) pra validar os certificados ACM — vazio se var.domain_name = null. Ver docs/dns-validacao.md."
  value = local.enable_https ? {
    regional   = module.certificates[0].regional_validation_records
    cloudfront = module.certificates[0].cloudfront_validation_records
  } : null
}
