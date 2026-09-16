# ARNs vêm do recurso de *validation* (não do certificate em si) — assim
# quem consome esse output (listener HTTPS do ALB, CloudFront) só é criado
# depois que a AWS confirmar o certificado como ISSUED.
output "regional_certificate_arn" {
  value = aws_acm_certificate_validation.regional.certificate_arn
}

output "cloudfront_certificate_arn" {
  value = try(aws_acm_certificate_validation.cloudfront[0].certificate_arn, null)
}

output "regional_validation_records" {
  description = "Registros DNS a criar manualmente no provedor (Hostinger) pra validar o certificado regional"
  value = [
    for o in aws_acm_certificate.regional.domain_validation_options : {
      name  = o.resource_record_name
      type  = o.resource_record_type
      value = o.resource_record_value
    }
  ]
}

output "cloudfront_validation_records" {
  description = "Registros DNS a criar manualmente no provedor (Hostinger) pra validar o certificado do CloudFront (us-east-1) — geralmente idênticos aos do regional, mesmo domínio"
  value = var.create_cloudfront_certificate ? [
    for o in aws_acm_certificate.cloudfront[0].domain_validation_options : {
      name  = o.resource_record_name
      type  = o.resource_record_type
      value = o.resource_record_value
    }
  ] : []
}
