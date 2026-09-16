output "user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "user_pool_arn" {
  value = aws_cognito_user_pool.this.arn
}

output "user_pool_client_id" {
  value = aws_cognito_user_pool_client.frontend.id
}

output "issuer_url" {
  description = "URL do issuer OIDC — o Frontend valida o JWT contra o JWKS em <issuer_url>/.well-known/jwks.json"
  value       = "https://${aws_cognito_user_pool.this.endpoint}"
}
