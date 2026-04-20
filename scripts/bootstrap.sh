#!/usr/bin/env bash
# Usage:
#   ./scripts/bootstrap.sh --repo "org/repo" --state-bucket "my-tf-state" --region "us-east-1"
set -euo pipefail

REGION="us-east-1"
ROLE_NAME="github-actions-asset-delivery"
POLICY_NAME="asset-delivery-deploy"
# OIDC lets GitHub exchange a short-lived JWT for temporary AWS credentials on each run.
# The alternative storing AWS_ACCESS_KEY_ID in GitHub Secrets  creates static keys that
# never expire and need manual rotation. OIDC eliminates that problem entirely.
OIDC_PROVIDER_URL="https://token.actions.githubusercontent.com"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)         GITHUB_REPO="$2"; shift 2;;
    --state-bucket) STATE_BUCKET="$2"; shift 2;;
    --region)       REGION="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

: "${GITHUB_REPO:?--repo is required}"
: "${STATE_BUCKET:?--state-bucket is required}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "→ AWS Account: $ACCOUNT_ID | Region: $REGION"

if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
  echo "✓ State bucket already exists: $STATE_BUCKET"
else
  aws s3api create-bucket \
    --bucket "$STATE_BUCKET" \
    --region "$REGION" \
    $([ "$REGION" != "us-east-1" ] && echo "--create-bucket-configuration LocationConstraint=$REGION" || echo "")
  # versioning means a corrupted or accidentally deleted state file can be rolled back
  # to a previous version rather than losing all tracked infrastructure state
  aws s3api put-bucket-versioning \
    --bucket "$STATE_BUCKET" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption \
    --bucket "$STATE_BUCKET" \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block \
    --bucket "$STATE_BUCKET" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  echo "✓ Created state bucket: $STATE_BUCKET"
fi

OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" 2>/dev/null; then
  echo "✓ OIDC provider already exists"
else
  # derive the thumbprint at runtime AWS requires it when registering the OIDC provider,
  # and GitHub rotates their CA cert, so a hardcoded value would silently break auth
  THUMBPRINT=$(echo | openssl s_client -servername token.actions.githubusercontent.com \
    -connect token.actions.githubusercontent.com:443 2>/dev/null \
    | openssl x509 -fingerprint -noout -sha1 \
    | sed 's/.*=//;s/://g' | tr '[:upper:]' '[:lower:]')
  aws iam create-open-id-connect-provider \
    --url "$OIDC_PROVIDER_URL" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "$THUMBPRINT"
  echo "✓ Created OIDC provider"
fi

# StringLike with the :* wildcard covers all refs  branches, tags, and PR merge refs.
# StringEquals would lock it to a single branch and break workflow_dispatch from other refs.
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${OIDC_ARN}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_REPO}:*"
        },
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
)

if aws iam get-role --role-name "$ROLE_NAME" 2>/dev/null; then
  echo "✓ IAM role already exists: $ROLE_NAME"
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST_POLICY"
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "Assumed by GitHub Actions for asset-delivery deployments"
  echo "✓ Created IAM role: $ROLE_NAME"
fi

# S3Assets uses Put* rather than enumerating individual actions because Terraform calls
# s3:PutBucketTagging after resource creation to reconcile default_tags that wasn't
# obvious until it failed. Put* covers it and any other put operations going forward.
DEPLOY_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3StateBackend",
      "Effect": "Allow",
      "Action": ["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::${STATE_BUCKET}",
        "arn:aws:s3:::${STATE_BUCKET}/*"
      ]
    },
    {
      "Sid": "S3Assets",
      "Effect": "Allow",
      "Action": ["s3:Get*","s3:List*","s3:Put*","s3:CreateBucket","s3:DeleteBucket",
        "s3:DeleteBucketPolicy","s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::*","arn:aws:s3:::*/*"]
    },
    {
      "Sid": "CloudFront",
      "Effect": "Allow",
      "Action": [
        "cloudfront:CreateDistribution","cloudfront:UpdateDistribution",
        "cloudfront:DeleteDistribution","cloudfront:GetDistribution",
        "cloudfront:GetDistributionConfig","cloudfront:ListDistributions",
        "cloudfront:CreateOriginAccessControl","cloudfront:UpdateOriginAccessControl",
        "cloudfront:DeleteOriginAccessControl","cloudfront:GetOriginAccessControl",
        "cloudfront:ListOriginAccessControls","cloudfront:CreateInvalidation",
        "cloudfront:CreateFunction","cloudfront:UpdateFunction","cloudfront:DeleteFunction",
        "cloudfront:DescribeFunction","cloudfront:PublishFunction","cloudfront:ListFunctions",
        "cloudfront:TagResource","cloudfront:UntagResource","cloudfront:ListTagsForResource",
        "cloudfront:ListCachePolicies","cloudfront:ListOriginRequestPolicies",
        "cloudfront:GetCachePolicy","cloudfront:GetOriginRequestPolicy","cloudfront:GetFunction"
      ],
      "Resource": ["*"]
    },
    {
      "Sid": "CloudWatch",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutMetricAlarm","cloudwatch:DeleteAlarms","cloudwatch:DescribeAlarms",
        "cloudwatch:PutDashboard","cloudwatch:DeleteDashboards","cloudwatch:GetDashboard",
        "cloudwatch:ListDashboards","cloudwatch:ListTagsForResource",
        "cloudwatch:TagResource","cloudwatch:UntagResource"
      ],
      "Resource": ["*"]
    }
  ]
}
EOF
)

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
if aws iam get-policy --policy-arn "$POLICY_ARN" 2>/dev/null; then
  echo "✓ Policy exists, updating..."
  # AWS enforces a hard limit of 5 versions per managed policy delete the non-default
  # ones first so creating a new version doesn't hit the limit on repeated bootstrap runs
  for v in $(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
    --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$v"
  done
  aws iam create-policy-version \
    --policy-arn "$POLICY_ARN" \
    --policy-document "$DEPLOY_POLICY" \
    --set-as-default
else
  POLICY_ARN=$(aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "$DEPLOY_POLICY" \
    --query "Policy.Arn" --output text)
  echo "✓ Created policy: $POLICY_ARN"
fi

aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo ""
echo "Done. Add to GitHub:"
echo "  Secret:   AWS_OIDC_ROLE_ARN = ${ROLE_ARN}"
echo "  Variable: TF_STATE_BUCKET   = ${STATE_BUCKET}"
