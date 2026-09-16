resource "aws_security_group" "this" {
  name_prefix = "${var.name}-"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.ingress_rules
    content {
      from_port       = ingress.value.from_port
      to_port         = ingress.value.to_port
      protocol        = ingress.value.protocol
      cidr_blocks     = try(ingress.value.cidr_blocks, null)
      security_groups = try(ingress.value.security_groups, null)
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# IAM role da instância. Sempre inclui o AmazonSSMManagedInstanceCore, que é
# o que viabiliza o acesso via Session Manager sem SSH/bastion
# (docs/flowqueue.md seção 2.7 e 5).
resource "aws_iam_role" "this" {
  name = "${var.name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Permissões específicas da camada (ex.: SQS SendMessage no Frontend,
# SQS ReceiveMessage + DynamoDB no Backend) — definidas por quem instancia
# o módulo.
resource "aws_iam_role_policy" "extra" {
  count = length(var.extra_policy_statements) > 0 ? 1 : 0

  name = "${var.name}-extra"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = var.extra_policy_statements
  })
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-profile"
  role = aws_iam_role.this.name
}

resource "aws_launch_template" "this" {
  name_prefix   = "${var.name}-"
  image_id      = var.ami_id
  instance_type = var.instance_type
  user_data     = var.user_data != "" ? base64encode(var.user_data) : null

  iam_instance_profile {
    name = aws_iam_instance_profile.this.name
  }

  network_interfaces {
    security_groups             = [aws_security_group.this.id]
    associate_public_ip_address = false
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = var.name })
  }

  tags = merge(var.tags, { Name = "${var.name}-lt" })
}

resource "aws_autoscaling_group" "this" {
  name                = "${var.name}-asg"
  vpc_zone_identifier = var.subnet_ids
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity
  health_check_type   = "EC2"
  target_group_arns   = var.target_group_arns

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  dynamic "tag" {
    for_each = merge(var.tags, { Name = var.name })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

# Target tracking (ex.: Frontend em ALBRequestCountPerTarget) — genérico,
# a métrica e o alvo são definidos por quem instancia o módulo
# (docs/melhorias.md item 5).
resource "aws_autoscaling_policy" "target_tracking" {
  count = var.enable_target_tracking_scaling ? 1 : 0

  name                   = "${var.name}-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.this.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    target_value = var.target_tracking_target_value

    predefined_metric_specification {
      predefined_metric_type = var.target_tracking_predefined_metric_type
      resource_label          = var.target_tracking_resource_label
    }
  }
}

# Step scaling (ex.: Backend por backlog da fila SQS) — as policies só
# ajustam a capacidade; o alarme do CloudWatch que as aciona fica em
# modules/observability, porque depende de métricas de outro módulo (SQS).
resource "aws_autoscaling_policy" "step_scale_out" {
  count = var.enable_step_scaling ? 1 : 0

  name                       = "${var.name}-scale-out"
  autoscaling_group_name    = aws_autoscaling_group.this.name
  policy_type                = "StepScaling"
  adjustment_type            = "ChangeInCapacity"
  estimated_instance_warmup = var.step_scaling_warmup_seconds

  step_adjustment {
    scaling_adjustment          = var.step_scaling_out_adjustment
    metric_interval_lower_bound = 0
  }
}

resource "aws_autoscaling_policy" "step_scale_in" {
  count = var.enable_step_scaling ? 1 : 0

  name                       = "${var.name}-scale-in"
  autoscaling_group_name    = aws_autoscaling_group.this.name
  policy_type                = "StepScaling"
  adjustment_type            = "ChangeInCapacity"
  estimated_instance_warmup = var.step_scaling_warmup_seconds

  step_adjustment {
    scaling_adjustment          = var.step_scaling_in_adjustment
    metric_interval_upper_bound = 0
  }
}
