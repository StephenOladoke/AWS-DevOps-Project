variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "asset-delivery"
}

variable "environment" {
  type    = string
  default = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "must be dev, staging, or prod"
  }
}

# Leave empty to skip SNS notifications useful for non-prod environments
# where you don't want pages firing on every test deployment
variable "cloudwatch_alarm_sns_arn" {
  type    = string
  default = ""
}

# PriceClass_100 covers North America and Europe only cheapest option.
# Switch to PriceClass_All if you need lower latency in Asia/South America.
variable "cloudfront_price_class" {
  type    = string
  default = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.cloudfront_price_class)
    error_message = "invalid price class"
  }
}

variable "error_rate_threshold" {
  type    = number
  default = 5
}
