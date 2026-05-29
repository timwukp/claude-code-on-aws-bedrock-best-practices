###############################################################################
# Claude Code observability — dashboard + alerts
#
# Sources:
#   /claude-code/audit  — every tool exec (HMAC chain)
#   /claude-code/drift  — real-time tamper events
#   /claude-code/hooks  — hook telemetry shim output
#
# Metric filters convert log events to CloudWatch metrics so SLO breaches can
# alarm without scanning logs.
###############################################################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
}

variable "region" { default = "us-east-1" }
variable "alert_topic_arn" {
  description = "SNS topic that on-call subscribes to"
  type        = string
}

provider "aws" { region = var.region }

# ----------------------------------------------------------------------------
# Metric filters: hook telemetry → metrics
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_log_metric_filter" "hook_blocked" {
  name           = "claude-hook-blocked"
  log_group_name = "/claude-code/hooks"
  pattern        = "{ $.status = \"blocked\" }"
  metric_transformation {
    name      = "HookBlocked"
    namespace = "ClaudeCode/Hooks"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "hook_crashed" {
  name           = "claude-hook-crashed"
  log_group_name = "/claude-code/hooks"
  pattern        = "{ $.status = \"crashed\" }"
  metric_transformation {
    name      = "HookCrashed"
    namespace = "ClaudeCode/Hooks"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "hook_timeout" {
  name           = "claude-hook-timeout"
  log_group_name = "/claude-code/hooks"
  pattern        = "{ $.status = \"timeout\" }"
  metric_transformation {
    name      = "HookTimeout"
    namespace = "ClaudeCode/Hooks"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "hook_latency" {
  name           = "claude-hook-latency"
  log_group_name = "/claude-code/hooks"
  pattern        = "{ $.duration_ms = * }"
  metric_transformation {
    name      = "HookDurationMs"
    namespace = "ClaudeCode/Hooks"
    value     = "$.duration_ms"
  }
}

resource "aws_cloudwatch_log_metric_filter" "drift_event" {
  name           = "claude-drift-event"
  log_group_name = "/claude-code/drift"
  pattern        = "{ $.kind = * }"
  metric_transformation {
    name      = "DriftEvent"
    namespace = "ClaudeCode/Drift"
    value     = "1"
  }
}

# ----------------------------------------------------------------------------
# Alarms — SLO breaches page on-call
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "hook_crash_rate" {
  alarm_name          = "claude-hook-crash-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HookCrashed"
  namespace           = "ClaudeCode/Hooks"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = "Any hook crash → fail-closed → tools blocked. Investigate immediately."
  alarm_actions       = [var.alert_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "hook_timeout_rate" {
  alarm_name          = "claude-hook-timeout-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HookTimeout"
  namespace           = "ClaudeCode/Hooks"
  period              = 300
  statistic           = "Sum"
  threshold           = 5 # >5 timeouts in 5 min — likely regression
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alert_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "hook_p99_latency" {
  alarm_name          = "claude-hook-p99-latency-slo"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "HookDurationMs"
  namespace           = "ClaudeCode/Hooks"
  period              = 300
  extended_statistic  = "p99"
  threshold           = 500 # SLO: p99 < 500ms
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alert_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "drift_detected" {
  alarm_name          = "claude-drift-detected"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "DriftEvent"
  namespace           = "ClaudeCode/Drift"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = "Managed config or hook file changed outside the deploy pipeline. Possible tamper."
  alarm_actions       = [var.alert_topic_arn]
}

# ----------------------------------------------------------------------------
# Dashboard
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "claude-code-enterprise"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric",
        x      = 0, y = 0, width = 12, height = 6,
        properties = {
          title  = "Hook outcomes (5-min rate)",
          region = var.region,
          metrics = [
            ["ClaudeCode/Hooks", "HookBlocked", { stat = "Sum" }],
            [".", "HookCrashed", { stat = "Sum" }],
            [".", "HookTimeout", { stat = "Sum" }],
          ],
          period = 300,
          view   = "timeSeries",
          stacked = false,
        }
      },
      {
        type   = "metric",
        x      = 12, y = 0, width = 12, height = 6,
        properties = {
          title  = "Hook latency (p50/p95/p99)",
          region = var.region,
          metrics = [
            ["ClaudeCode/Hooks", "HookDurationMs", { stat = "p50" }],
            ["...", { stat = "p95" }],
            ["...", { stat = "p99" }],
          ],
          period = 60,
          view   = "timeSeries",
        }
      },
      {
        type   = "metric",
        x      = 0, y = 6, width = 12, height = 6,
        properties = {
          title  = "Drift events",
          region = var.region,
          metrics = [["ClaudeCode/Drift", "DriftEvent", { stat = "Sum" }]],
          period = 60,
        }
      },
      {
        type   = "log",
        x      = 12, y = 6, width = 12, height = 6,
        properties = {
          title  = "Recent crashes",
          region = var.region,
          query  = "SOURCE '/claude-code/hooks' | filter status=\"crashed\" | sort @timestamp desc | limit 25",
          view   = "table",
        }
      },
    ]
  })
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}
