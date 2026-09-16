# AWS Systems Manager – Parameter Store: configurações/segredos centralizados
# consumidos pelas instâncias EC2, em vez de hardcoded (docs/flowqueue.md
# seção 2.7).
resource "aws_ssm_parameter" "this" {
  for_each = var.parameters

  name  = each.key
  type  = each.value.type
  value = each.value.value

  tags = var.tags
}
