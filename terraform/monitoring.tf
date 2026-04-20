# Two evaluation periods before alarming to avoid false positives from brief spikes.
# In production I'd wire alarm_actions to an SNS topic that pages on-call.
resource "aws_cloudwatch_metric_alarm" "cloudfront_5xx_rate" {
  alarm_name          = "${var.project_name}-5xx-rate-${var.environment}"
  alarm_description   = "CloudFront 5xx error rate exceeded ${var.error_rate_threshold}% over 5 minutes"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  threshold           = var.error_rate_threshold
  treat_missing_data  = "notBreaching"

  metric_name = "5xxErrorRate"
  namespace   = "AWS/CloudFront"
  period      = 300
  statistic   = "Average"

  dimensions = {
    DistributionId = aws_cloudfront_distribution.cdn.id
    Region         = "Global"
  }

  alarm_actions = var.cloudwatch_alarm_sns_arn != "" ? [var.cloudwatch_alarm_sns_arn] : []
  ok_actions    = var.cloudwatch_alarm_sns_arn != "" ? [var.cloudwatch_alarm_sns_arn] : []
}

resource "aws_cloudwatch_dashboard" "cdn" {
  dashboard_name = "${var.project_name}-cdn-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "5xx Error Rate (%)"
          view   = "timeSeries"
          region = "us-east-1"
          metrics = [
            ["AWS/CloudFront", "5xxErrorRate",
              "DistributionId", aws_cloudfront_distribution.cdn.id,
            "Region", "Global"]
          ]
          period = 300
          stat   = "Average"
          annotations = {
            horizontal = [{ value = var.error_rate_threshold, label = "Alarm threshold", color = "#ff0000" }]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Requests"
          view   = "timeSeries"
          region = "us-east-1"
          metrics = [
            ["AWS/CloudFront", "Requests",
              "DistributionId", aws_cloudfront_distribution.cdn.id,
            "Region", "Global"]
          ]
          period = 300
          stat   = "Sum"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Cache Hit Rate (%)"
          view   = "timeSeries"
          region = "us-east-1"
          metrics = [
            ["AWS/CloudFront", "CacheHitRate",
              "DistributionId", aws_cloudfront_distribution.cdn.id,
            "Region", "Global"]
          ]
          period = 300
          stat   = "Average"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Total Error Rate (%)"
          view   = "timeSeries"
          region = "us-east-1"
          metrics = [
            ["AWS/CloudFront", "TotalErrorRate",
              "DistributionId", aws_cloudfront_distribution.cdn.id,
            "Region", "Global"]
          ]
          period = 300
          stat   = "Average"
        }
      }
    ]
  })
}
