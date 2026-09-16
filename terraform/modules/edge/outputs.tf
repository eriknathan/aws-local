output "alb_arn" {
  value = aws_lb.this.arn
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_arn_suffix" {
  description = "Usado como dimensão LoadBalancer nos alarmes do CloudWatch (modules/observability)"
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  description = "Usado no resource_label do target tracking ALBRequestCountPerTarget (modules/compute)"
  value       = aws_lb_target_group.frontend.arn_suffix
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "target_group_arn" {
  value = aws_lb_target_group.frontend.arn
}

output "cloudfront_domain_name" {
  value = try(aws_cloudfront_distribution.this[0].domain_name, null)
}
