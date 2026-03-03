#!/usr/bin/env bash
# quickec2 — S3 bucket creation

# ─── create_s3_bucket ─────────────────────────────────────────────────────────
create_s3_bucket() {
  local bucket_name="$1"
  local region="$2"
  local project="$3"

  log_step "Creating S3 bucket"

  log_info "Creating bucket: ${bucket_name}..."

  # LocationConstraint is required for non-us-east-1 regions
  if [[ "$region" == "us-east-1" ]]; then
    aws_cmd s3api create-bucket \
      --bucket "$bucket_name" \
      --region "$region" > /dev/null
  else
    aws_cmd s3api create-bucket \
      --bucket "$bucket_name" \
      --region "$region" \
      --create-bucket-configuration "LocationConstraint=${region}" > /dev/null
  fi
  save_resource "S3_BUCKET_NAME" "$bucket_name"

  # Tag the bucket
  aws_cmd s3api put-bucket-tagging \
    --bucket "$bucket_name" \
    --tagging "TagSet=[{Key=Name,Value=${project}-s3},{Key=CreatedBy,Value=quickec2},{Key=CreatedAt,Value=$(date -u +%Y-%m-%dT%H:%M:%SZ)}]" \
    --region "$region" > /dev/null 2>&1 || true

  # Block all public access
  aws_cmd s3api put-public-access-block \
    --bucket "$bucket_name" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
    --region "$region" > /dev/null 2>&1 || true

  log_success "S3 bucket: ${bucket_name} (public access blocked)"
}
