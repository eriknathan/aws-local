# Provider único: aponta para o Floci local por padrão (var.use_local_endpoint
# = true). Para apontar para a AWS real no futuro, basta definir
# use_local_endpoint = false e ajustar região/credenciais — nenhum módulo
# precisa mudar (mesmo padrão de migração de LocalStack descrito em
# docs/floci.md, seção 10).
provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key

  skip_credentials_validation = var.use_local_endpoint
  skip_requesting_account_id  = var.use_local_endpoint
  skip_metadata_api_check     = var.use_local_endpoint
  s3_use_path_style           = var.use_local_endpoint

  dynamic "endpoints" {
    for_each = var.use_local_endpoint ? [1] : []
    content {
      ec2         = var.aws_endpoint_url
      autoscaling = var.aws_endpoint_url
      elbv2       = var.aws_endpoint_url
      sqs         = var.aws_endpoint_url
      dynamodb    = var.aws_endpoint_url
      ssm         = var.aws_endpoint_url
      iam         = var.aws_endpoint_url
      sts         = var.aws_endpoint_url
      cloudfront  = var.aws_endpoint_url
      s3          = var.aws_endpoint_url
    }
  }
}
