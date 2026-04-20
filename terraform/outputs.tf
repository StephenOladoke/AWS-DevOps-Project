# distribution_id is used in the CI pipeline to run cache invalidations after deploy
output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.cdn.id
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.cdn.domain_name
}

# smoke test hits this URL after every deployment to confirm the origin is reachable
output "test_file_url" {
  value = "https://${aws_cloudfront_distribution.cdn.domain_name}/test.txt"
}

output "assets_bucket_name" {
  value = aws_s3_bucket.assets.id
}

output "assets_bucket_arn" {
  value = aws_s3_bucket.assets.arn
}

output "cloudwatch_alarm_name" {
  value = aws_cloudwatch_metric_alarm.cloudfront_5xx_rate.alarm_name
}

output "cloudwatch_dashboard_url" {
  value = "https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=${aws_cloudwatch_dashboard.cdn.dashboard_name}"
}
