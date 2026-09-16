locals {
  # Só restringe o ALB ao CloudFront (prefix list + header secreto) quando
  # os dois estão ligados — sem CloudFront, o ALB precisa continuar aberto
  # pra ser acessado direto (docs/melhorias.md item 3).
  restrict_alb_to_cloudfront = var.enable_https && var.enable_cloudfront
}

# Prefix list gerenciada pela AWS com os ranges de IP de saída do CloudFront
# — usada no security group do ALB no lugar de 0.0.0.0/0 quando restringimos
# o acesso só ao CloudFront.
data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  count = local.restrict_alb_to_cloudfront ? 1 : 0

  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# Security group do Application Load Balancer — único ponto público dentro
# da VPC (docs/flowqueue.md seção 2.1 e 5).
resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = local.restrict_alb_to_cloudfront ? [] : [1]
    content {
      description = "HTTP publico (via CloudFront)"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  dynamic "ingress" {
    for_each = local.restrict_alb_to_cloudfront ? [] : [1]
    content {
      description = "HTTPS publico (via CloudFront)"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  dynamic "ingress" {
    for_each = local.restrict_alb_to_cloudfront ? [1] : []
    content {
      description     = "HTTPS só a partir dos IPs de saída do CloudFront"
      from_port       = 443
      to_port         = 443
      protocol        = "tcp"
      prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront_origin_facing[0].id]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-alb-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  tags = merge(var.tags, { Name = "${var.name}-alb" })
}

resource "aws_lb_target_group" "frontend" {
  name        = "${var.name}-frontend-tg"
  port        = var.target_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
  }

  tags = merge(var.tags, { Name = "${var.name}-frontend-tg" })
}

# Opcional: o CreateListener do ELBv2 no Floci hoje retorna 500
# ("InternalFailure: Unexpected error: null") de forma determinística,
# reproduzível até via AWS CLI puro — não é um problema deste código.
# Desabilite com enable_listener = false até o Floci corrigir; o
# target_group_arn já existe e o Backend/Frontend não dependem do listener.
#
# Com enable_https, vira redirect 301 pra HTTPS em vez de forward direto
# (docs/melhorias.md item 3).
resource "aws_lb_listener" "http" {
  count = var.enable_listener ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type              = var.enable_https ? "redirect" : "forward"
    target_group_arn  = var.enable_https ? null : aws_lb_target_group.frontend.arn

    dynamic "redirect" {
      for_each = var.enable_https ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

# Listener HTTPS (docs/melhorias.md item 3). Sem restrict_alb_to_cloudfront,
# encaminha direto pro target group (ALB acessível diretamente por HTTPS).
# Com restrict_alb_to_cloudfront, a ação default é 403 fixo — só a rule
# abaixo (que exige o header secreto do CloudFront) encaminha de verdade.
resource "aws_lb_listener" "https" {
  count = var.enable_listener && var.enable_https ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type              = local.restrict_alb_to_cloudfront ? "fixed-response" : "forward"
    target_group_arn  = local.restrict_alb_to_cloudfront ? null : aws_lb_target_group.frontend.arn

    dynamic "fixed_response" {
      for_each = local.restrict_alb_to_cloudfront ? [1] : []
      content {
        content_type = "text/plain"
        message_body = "Forbidden"
        status_code  = "403"
      }
    }
  }
}

# Só encaminha tráfego HTTPS que já veio com o header secreto que o
# CloudFront injeta — quem acessa o ALB direto (sem passar pelo CloudFront)
# cai na ação default acima (403).
resource "aws_lb_listener_rule" "https_cloudfront_only" {
  count = var.enable_listener && var.enable_https && local.restrict_alb_to_cloudfront ? 1 : 0

  listener_arn = aws_lb_listener.https[0].arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values            = [var.origin_secret_header_value]
    }
  }
}

# CloudFront na frente do ALB — CDN de borda (docs/flowqueue.md seção 2.1).
# Opcional: em caso de comportamento inesperado no Floci, desabilite via
# enable_cloudfront = false e siga apenas com o ALB.
resource "aws_cloudfront_distribution" "this" {
  count = var.enable_cloudfront ? 1 : 0

  enabled = true
  comment = "${var.name} - CDN de borda para o ALB"
  web_acl_id = var.waf_web_acl_arn

  origin {
    domain_name = aws_lb.this.dns_name
    origin_id   = "${var.name}-alb-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = local.restrict_alb_to_cloudfront ? "https-only" : "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    dynamic "custom_header" {
      for_each = local.restrict_alb_to_cloudfront ? [1] : []
      content {
        name  = "X-Origin-Verify"
        value = var.origin_secret_header_value
      }
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "${var.name}-alb-origin"
    viewer_protocol_policy = var.enable_https ? "redirect-to-https" : "allow-all"

    forwarded_values {
      query_string = true

      cookies {
        forward = "all"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.enable_https ? null : true
    acm_certificate_arn            = var.enable_https ? var.acm_certificate_arn_cloudfront : null
    ssl_support_method             = var.enable_https ? "sni-only" : null
    minimum_protocol_version       = var.enable_https ? "TLSv1.2_2021" : null
  }

  tags = merge(var.tags, { Name = "${var.name}-cloudfront" })
}
