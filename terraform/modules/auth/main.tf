# Cognito User Pool — autenticação de usuário final pra API de
# status/download do recibo (docs/melhorias.md item 6). Login por e-mail;
# validação do JWT emitido aqui é responsabilidade do código do Frontend
# (ver ../docs/frontend-auth.md). Sem integração nativa do ALB
# (authenticate-cognito) de propósito: isso exige listener HTTPS + domínio
# próprio, que dependem do item 3 (ainda pendente).
resource "aws_cognito_user_pool" "this" {
  name = "${var.name}-users"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = var.password_minimum_length
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }

  mfa_configuration = var.mfa_configuration

  tags = merge(var.tags, { Name = "${var.name}-users" })
}

# App client sem secret (public client) — pensado pra um cliente
# SPA/mobile futuro autenticar o usuário final diretamente via
# InitiateAuth, sem Hosted UI.
resource "aws_cognito_user_pool_client" "frontend" {
  name         = "${var.name}-frontend-client"
  user_pool_id = aws_cognito_user_pool.this.id

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  generate_secret = false

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}
