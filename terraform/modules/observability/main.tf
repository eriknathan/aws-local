# Destino comum de todos os alarmes (docs/melhorias.md item 5). Sem
# var.alarm_email, o tópico fica pronto mas sem inscrição — inscreva um
# e-mail depois sem precisar mudar Terraform.
resource "aws_sns_topic" "alarms" {
  name = "${var.name}-alarms"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alarm_email != null ? 1 : 0

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# --- Scaling do Backend por backlog da fila principal (step scaling
# clássico, opção "a" do plano) — os dois alarmes abaixo são o gatilho das
# aws_autoscaling_policy criadas em modules/compute; sem alarme, essas
# policies nunca disparam sozinhas. ---

resource "aws_cloudwatch_metric_alarm" "backend_scale_out" {
  alarm_name          = "${var.name}-backend-scale-out"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.evaluation_periods
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = var.period_seconds
  statistic           = "Average"
  threshold           = var.queue_backlog_scale_out_threshold
  alarm_description   = "Backlog da fila principal acima do threshold — aciona scale-out do Backend"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.main_queue_name
  }

  alarm_actions = [var.backend_scale_out_policy_arn, aws_sns_topic.alarms.arn]
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "backend_scale_in" {
  alarm_name          = "${var.name}-backend-scale-in"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = var.evaluation_periods
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = var.period_seconds
  statistic           = "Average"
  threshold           = var.queue_backlog_scale_in_threshold
  alarm_description   = "Backlog da fila principal abaixo do threshold — aciona scale-in do Backend"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.main_queue_name
  }

  alarm_actions = [var.backend_scale_in_policy_arn]
  tags          = var.tags
}

# --- Alarmes de notificação pura (sem scaling) ---

resource "aws_cloudwatch_metric_alarm" "queue_oldest_message_age" {
  alarm_name          = "${var.name}-queue-oldest-message-age"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.evaluation_periods
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = var.period_seconds
  statistic           = "Maximum"
  threshold           = var.queue_oldest_message_age_threshold_seconds
  alarm_description   = "Mensagem mais antiga da fila principal esperando há mais tempo que o threshold — backlog crescendo mais rápido que o processamento"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.main_queue_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${var.name}-dlq-not-empty"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = var.period_seconds
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Qualquer mensagem na DLQ indica falha recorrente de processamento — gatilho de investigação"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.dlq_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.name}-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.evaluation_periods
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = var.period_seconds
  statistic           = "Sum"
  threshold           = var.alb_5xx_threshold
  alarm_description   = "Taxa de erro 5xx do ALB acima do threshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_latency" {
  alarm_name          = "${var.name}-alb-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.evaluation_periods
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = var.period_seconds
  statistic           = "Average"
  threshold           = var.alb_latency_threshold_seconds
  alarm_description   = "Latência média do ALB acima do threshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  tags          = var.tags
}
