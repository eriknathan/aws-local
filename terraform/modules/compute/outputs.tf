output "security_group_id" {
  value = aws_security_group.this.id
}

output "role_arn" {
  value = aws_iam_role.this.arn
}

output "role_name" {
  value = aws_iam_role.this.name
}

output "instance_profile_name" {
  value = aws_iam_instance_profile.this.name
}

output "launch_template_id" {
  value = aws_launch_template.this.id
}

output "asg_name" {
  value = aws_autoscaling_group.this.name
}

output "asg_arn" {
  value = aws_autoscaling_group.this.arn
}

output "target_tracking_policy_arn" {
  value = try(aws_autoscaling_policy.target_tracking[0].arn, null)
}

output "step_scale_out_policy_arn" {
  value = try(aws_autoscaling_policy.step_scale_out[0].arn, null)
}

output "step_scale_in_policy_arn" {
  value = try(aws_autoscaling_policy.step_scale_in[0].arn, null)
}
