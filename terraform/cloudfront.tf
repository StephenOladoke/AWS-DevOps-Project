# Using OAC instead of the legacy OAI pattern, OAI is being phased out by AWS
# and doesn't support all S3 features. OAC uses SigV4 signing which is more secure.
resource "aws_cloudfront_origin_access_control" "assets" {
  name                              = "${var.project_name}-oac-${var.environment}"
  description                       = "OAC for private S3 asset delivery"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.project_name} (${var.environment})"
  default_root_object = "index.html"
  price_class         = var.cloudfront_price_class
  http_version        = "http2and3"

  # Must use bucket_regional_domain_name here, not bucket_domain_name.
  # The global endpoint doesn't work correctly with OAC SigV4 signing.
  origin {
    domain_name              = aws_s3_bucket.assets.bucket_regional_domain_name
    origin_id                = "s3-assets"
    origin_access_control_id = aws_cloudfront_origin_access_control.assets.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-assets"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # Using AWS managed policies rather than custom ones to reduce maintenance overhead.
    # In a production setup with stricter cache requirements, a custom policy would give more control.
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_optimized.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.cors_s3_origin.id

    # Security headers are injected on viewer-response, not viewer-request.
    # viewer-request fires before the origin responds, so event.response doesn't exist there.
    function_association {
      event_type   = "viewer-response"
      function_arn = aws_cloudfront_function.security_headers.arn
    }
  }

  # S3 returns 403 for missing objects when the bucket is private, not 404.
  # Mapping it to 404 here avoids leaking that the bucket exists.
  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 10
  }

  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 10
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # TLSv1.2_2021 is the minimum, drops support for TLS 1.0 and 1.1 which are deprecated
  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1.2_2021"
  }

  logging_config {
    bucket          = aws_s3_bucket.logs.bucket_domain_name
    prefix          = "cloudfront/"
    include_cookies = false
  }

  depends_on = [aws_s3_bucket_public_access_block.assets]
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "cors_s3_origin" {
  name = "Managed-CORS-S3Origin"
}

resource "aws_cloudfront_function" "security_headers" {
  name    = "${var.project_name}-security-headers-${var.environment}"
  runtime = "cloudfront-js-2.0"
  comment = "Injects security response headers on every request"
  publish = true

  code = <<-EOF
    async function handler(event) {
      var response = event.response;
      var headers  = response.headers;

      headers['strict-transport-security'] = { value: 'max-age=63072000; includeSubDomains; preload' };
      headers['x-content-type-options']    = { value: 'nosniff' };
      headers['x-frame-options']           = { value: 'DENY' };
      headers['x-xss-protection']          = { value: '1; mode=block' };
      headers['referrer-policy']           = { value: 'strict-origin-when-cross-origin' };
      headers['permissions-policy']        = { value: 'geolocation=(), microphone=(), camera=()' };

      return response;
    }
  EOF
}
