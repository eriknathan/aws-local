output "parameter_names" {
  value = keys(aws_ssm_parameter.this)
}

output "parameter_arns" {
  value = { for k, v in aws_ssm_parameter.this : k => v.arn }
}
