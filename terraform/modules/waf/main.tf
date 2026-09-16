# Web ACL na frente do CloudFront — scope CLOUDFRONT só existe em us-east-1,
# não importa a região principal (docs/melhorias.md item 3). Duas regras
# gerenciadas da AWS, conforme o plano ("pelo menos" essas duas).
resource "aws_wafv2_web_acl" "cloudfront" {
  provider = aws.us_east_1

  name        = "${var.name}-cloudfront-waf"
  description = "Regras gerenciadas da AWS na frente do CloudFront"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 0

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-common-rule-set"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-cloudfront-waf"
    sampled_requests_enabled   = true
  }

  tags = merge(var.tags, { Name = "${var.name}-cloudfront-waf" })
}
