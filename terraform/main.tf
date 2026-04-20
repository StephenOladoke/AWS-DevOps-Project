terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # backend config is passed in at init time via -backend-config flags in CI
  # so the same code works across environments without hardcoding bucket names here
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  # default_tags applies to every resource in this module, so I don't have
  # to remember to tag things individually
  default_tags {
    tags = {
      Project     = "asset-delivery"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# CloudFront metrics only exist in us-east-1 regardless of where the bucket lives,
# so I need a separate aliased provider to deploy the alarm into the right region
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "asset-delivery"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# random suffix keeps bucket names globally unique without hardcoding account IDs
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  bucket_name = "${var.project_name}-assets-${var.environment}-${random_id.suffix.hex}"
  logs_bucket = "${var.project_name}-logs-${var.environment}-${random_id.suffix.hex}"
}
