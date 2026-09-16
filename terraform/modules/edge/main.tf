# Security group do Application Load Balancer — único ponto público dentro
# da VPC (docs/flowqueue.md seção 2.1 e 5).
resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP publico (via CloudFront)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS publico (via CloudFront)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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
resource "aws_lb_listener" "http" {
  count = var.enable_listener ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

# CloudFront na frente do ALB — CDN de borda (docs/flowqueue.md seção 2.1).
# Opcional: em caso de comportamento inesperado no Floci, desabilite via
# enable_cloudfront = false e siga apenas com o ALB.
resource "aws_cloudfront_distribution" "this" {
  count = var.enable_cloudfront ? 1 : 0

  enabled = true
  comment = "${var.name} - CDN de borda para o ALB"

  origin {
    domain_name = aws_lb.this.dns_name
    origin_id   = "${var.name}-alb-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "${var.name}-alb-origin"
    viewer_protocol_policy = "allow-all"

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
    cloudfront_default_certificate = true
  }

  tags = merge(var.tags, { Name = "${var.name}-cloudfront" })
}
