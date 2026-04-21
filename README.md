# AWS Asset Delivery, Secure S3 + CloudFront

## The Task

Provisioning a private S3 bucket, served it through CloudFront using Origin Access Control for security, automated deployments with GitHub Actions, and set up a CloudWatch alarm for 5xx error monitoring.

## My Approach

I went with Terraform over CDK, it's more readable for infrastructure reviews and the state management story is cleaner for a single-module project like this. For GitHub Actions auth I used OIDC instead of storing AWS keys as secrets, which meant a bit of upfront bootstrap work but no long-lived credentials sitting anywhere.

The architecture I landed on is straightforward:

```
User → CloudFront (HTTPS only)
            │  OAC SigV4 signing
            ▼
      Private S3 Bucket  ← zero public access
            │
            ▼
      CloudWatch Alarm (5xx rate > 5%)
```

## What I Built

```
terraform/
  main.tf           providers, backend, tags
  variables.tf      env, region, naming
  s3.tf             assets + logs buckets
  cloudfront.tf     cdn, oac, security headers fn
  monitoring.tf     5xx alarm + dashboard
  outputs.tf        bucket name, cdn id, test url

.github/workflows/
  deploy.yml        validate → plan → apply → destroy

scripts/
  bootstrap.sh      oidc setup + state bucket
```

## Security Decisions I Made

**OAC not OAI** I used Origin Access Control, the current AWS standard. OAI is legacy and being phased out. I scoped the bucket policy to only allow `s3:GetObject` from the specific CloudFront distribution ARN, not from CloudFront broadly, so no other distribution can piggyback on this bucket.

**All four public access block flags** I set all of them to true. Belt and suspenders, makes it impossible to accidentally expose the bucket.

**TLS enforced at two layers** I denied non-HTTPS at the S3 bucket policy level in addition to CloudFront redirecting to HTTPS. That way even if someone bypasses CloudFront and hits S3 directly, the request gets rejected.

**TLS 1.2 minimum** I dropped 1.0 and 1.1 at the distribution level. Both are deprecated and shouldn't be negotiated.

**OIDC for GitHub Actions** I didn't want `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` sitting in GitHub secrets. Instead GitHub exchanges a short-lived OIDC token for temporary AWS credentials on each run, scoped to only the IAM role I provisioned.

## What Actually Broke

Getting the code written wasn't the hard part. Here's what actually took my time:

**IAM permissions were too tight**

My first few runs failed during `terraform apply` because the IAM role I'd provisioned was missing `s3:PutBucketTagging`. Terraform tags resources after creating them and I hadn't accounted for that. I updated the bootstrap script to use `s3:Put*` to cover tagging and any other put operations, re-ran bootstrap locally to push the updated policy to AWS, then triggered the next run.

**CloudWatch had the same pattern**

Same issue, different service. The alarm was being created fine but Terraform calls `ListTagsForResource` after creation to reconcile state and that wasn't in my policy. I added `cloudwatch:ListTagsForResource`, `cloudwatch:TagResource`, and `cloudwatch:UntagResource` and redeployed.

**Tainted resources in Terraform state**

After a couple of failed applies, Terraform had marked my S3 buckets as tainted meaning it would destroy and recreate them on the next run. The assets bucket had `force_destroy = false` which prevents deletion of non-empty buckets, and Terraform had already uploaded `test.txt` in there so it failed trying to tear it down. I temporarily flipped `force_destroy = true`, let the recreation go through, then flipped it back.

**503 on every single request**

Everything deployed cleanly but my smoke test was returning 503 on all retry attempts. The distribution was up, bucket had the file, policy looked correct, I spent time looking at the wrong things.

The actual bug was in my CloudFront security headers function. I had attached it to `viewer-request` but the code was reading `event.response`. On a viewer-request there is no response object, the request hasn't hit the origin yet. My function was throwing a JavaScript error on every incoming request which CloudFront translates to a 503. I moved it to `viewer-response` and it passed immediately.

## Proof of Life
https://d19ogve0k33iqc.cloudfront.net/test.txt


## How To Deploy

**1. Bootstrap (one-time, run locally)**

```bash
./scripts/bootstrap.sh \
  --repo  "StephenOladoke/AWS-DevOps-Project" \
  --state-bucket "asset-delivery-tf-state" \
  --region "us-east-1"
```

This creates the Terraform state bucket, registers the GitHub OIDC provider in your AWS account, and sets up the IAM role. It prints the two values you need to add to GitHub at the end.

**2. Push to main**

```bash
git push origin main
```

The pipeline validates, applies, invalidates the CloudFront cache, and runs a smoke test against `test.txt`. Job summary shows the live URL when it's done.
