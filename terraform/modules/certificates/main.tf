# Certificado regional, usado pelo listener HTTPS do ALB (docs/melhorias.md
# item 3). Validação por DNS — o domínio não está no Route53 (é registrado
# na Hostinger), então não dá pra criar o CNAME de validação via
# aws_route53_record. Os registros ficam nos outputs pra você criar
# manualmente no painel de DNS do provedor (ver ../docs/dns-validacao.md).
resource "aws_acm_certificate" "regional" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, { Name = var.domain_name })
}

# aws_acm_certificate_validation sem validation_record_fqdns: sem essa
# lista, o recurso só espera o status do certificado virar ISSUED — funciona
# igual, mesmo o CNAME tendo sido criado manualmente fora do Terraform. O
# apply fica parado aqui até isso acontecer (ou até o timeout).
resource "aws_acm_certificate_validation" "regional" {
  certificate_arn = aws_acm_certificate.regional.arn

  timeouts {
    create = "1h"
  }
}

# Certificado em us-east-1, exigido pelo CloudFront (mesmo domínio).
resource "aws_acm_certificate" "cloudfront" {
  count = var.create_cloudfront_certificate ? 1 : 0

  provider = aws.us_east_1

  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, { Name = "${var.domain_name}-cloudfront" })
}

resource "aws_acm_certificate_validation" "cloudfront" {
  count = var.create_cloudfront_certificate ? 1 : 0

  provider = aws.us_east_1

  certificate_arn = aws_acm_certificate.cloudfront[0].arn

  timeouts {
    create = "1h"
  }
}
