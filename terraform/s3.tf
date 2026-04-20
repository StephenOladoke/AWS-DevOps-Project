# Logs bucket uses force_destroy=true intentionally , it only holds access logs,
# so there's no risk in wiping it on teardown
resource "aws_s3_bucket" "logs" {
  bucket        = local.logs_bucket
  force_destroy = true
}

# BucketOwnerPreferred is required here so the log-delivery-write ACL below
# can actually grant write access to the S3 log delivery service
resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "logs" {
  depends_on = [aws_s3_bucket_ownership_controls.logs]
  bucket     = aws_s3_bucket.logs.id
  acl        = "log-delivery-write"
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {
      prefix = ""
    }

    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# force_destroy=false on the assets bucket to prevent accidental data loss in prod.
# If a destroy is needed, empty the bucket manually first or flip this temporarily.
resource "aws_s3_bucket" "assets" {
  bucket        = local.bucket_name
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "assets" {
  bucket = aws_s3_bucket.assets.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    # bucket_key_enabled reduces SSE-S3 API call costs at scale
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_logging" "assets" {
  bucket        = aws_s3_bucket.assets.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "s3-access/"
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# BucketOwnerEnforced disables ACLs entirely all access goes through bucket policy only.
# This is the recommended setting when using OAC since there's no need for ACL-based access.
resource "aws_s3_bucket_ownership_controls" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "assets_bucket_policy" {
  # Only allow reads from this specific CloudFront distribution, not from CloudFront broadly.
  # Scoping to the distribution ARN prevents other CF distributions from accessing this bucket.
  statement {
    sid    = "AllowCloudFrontOACRead"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.assets.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.cdn.arn]
    }
  }

  # Enforce TLS at the S3 level as a second layer CloudFront already redirects to HTTPS
  # but this blocks any direct S3 access attempts over plain HTTP
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.assets.arn, "${aws_s3_bucket.assets.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "assets" {
  bucket     = aws_s3_bucket.assets.id
  policy     = data.aws_iam_policy_document.assets_bucket_policy.json
  depends_on = [aws_cloudfront_distribution.cdn]
}

resource "aws_s3_object" "test_file" {
  bucket       = aws_s3_bucket.assets.id
  key          = "test.txt"
  content      = "Hello from CloudFront + S3 (OAC) — deployment successful!\n"
  content_type = "text/plain"
  etag         = md5("Hello from CloudFront + S3 (OAC) — deployment successful!\n")
}
