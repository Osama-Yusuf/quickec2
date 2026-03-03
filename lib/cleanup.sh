#!/usr/bin/env bash
# quickec2 — cleanup/teardown functions

# ─── delete_resource ──────────────────────────────────────────────────────────
# Safe deletion wrapper: runs command, suppresses errors
delete_resource() {
  local description="$1"
  shift
  echo -n "  Deleting ${description}... "
  if "$@" 2>/dev/null; then
    echo "done."
  else
    echo "skipped (may not exist or already deleted)."
  fi
}

# ─── cleanup_ec2 ──────────────────────────────────────────────────────────────
cleanup_ec2() {
  local region="$1"

  log_step "Cleaning up EC2 resources"

  # Terminate instance
  if [[ -n "${INSTANCE_ID:-}" ]]; then
    delete_resource "instance ${INSTANCE_ID}" \
      aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$region"

    echo "  Waiting for instance to terminate..."
    aws ec2 wait instance-terminated \
      --instance-ids "$INSTANCE_ID" \
      --region "$region" 2>/dev/null || true
    echo "  Instance terminated."
  fi

  # Delete key pair (only if we created it)
  if [[ "${KEY_CREATED:-}" == "true" && -n "${KEY_NAME:-}" ]]; then
    delete_resource "key pair ${KEY_NAME}" \
      aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$region"

    # Remove local .pem file
    local key_file="${QUICKEC2_DIR}/${KEY_NAME}.pem"
    if [[ -f "$key_file" ]]; then
      rm -f "$key_file"
      echo "  Removed local key file: ${key_file}"
    fi
  fi

  # Release EC2 Elastic IP
  if [[ -n "${EC2_EIP_ALLOC_ID:-}" ]]; then
    delete_resource "EC2 Elastic IP ${EC2_EIP_ALLOC_ID}" \
      aws ec2 release-address --allocation-id "$EC2_EIP_ALLOC_ID" --region "$region"
  fi

  # Remove role from instance profile
  if [[ -n "${INSTANCE_PROFILE_NAME:-}" && -n "${ROLE_NAME:-}" ]]; then
    delete_resource "role from instance profile" \
      aws iam remove-role-from-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --role-name "$ROLE_NAME"
  fi

  # Delete instance profile
  if [[ -n "${INSTANCE_PROFILE_NAME:-}" ]]; then
    delete_resource "instance profile ${INSTANCE_PROFILE_NAME}" \
      aws iam delete-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME"
  fi

  # Detach managed policies and delete inline policies
  if [[ -n "${ROLE_NAME:-}" ]]; then
    delete_resource "SSM policy from role" \
      aws iam detach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

    # Delete inline policies
    local inline_policies
    inline_policies=$(aws iam list-role-policies \
      --role-name "$ROLE_NAME" \
      --query 'PolicyNames' \
      --output text 2>/dev/null || echo "")
    for policy in $inline_policies; do
      delete_resource "inline policy ${policy}" \
        aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$policy"
    done

    delete_resource "IAM role ${ROLE_NAME}" \
      aws iam delete-role --role-name "$ROLE_NAME"
  fi

  # Delete security group
  if [[ -n "${SG_ID:-}" ]]; then
    delete_resource "security group ${SG_ID}" \
      aws ec2 delete-security-group --group-id "$SG_ID" --region "$region"
  fi
}

# ─── cleanup_vpc ──────────────────────────────────────────────────────────────
cleanup_vpc() {
  local region="$1"

  log_step "Cleaning up VPC resources"

  # Delete NAT Gateway
  if [[ -n "${NAT_GW_ID:-}" ]]; then
    delete_resource "NAT Gateway ${NAT_GW_ID}" \
      aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_GW_ID" --region "$region"

    echo "  Waiting for NAT Gateway to be deleted (this takes 1-2 minutes)..."
    for i in $(seq 1 30); do
      local nat_state
      nat_state=$(aws ec2 describe-nat-gateways \
        --nat-gateway-ids "$NAT_GW_ID" \
        --region "$region" \
        --query 'NatGateways[0].State' \
        --output text 2>/dev/null || echo "deleted")
      if [[ "$nat_state" == "deleted" ]]; then
        break
      fi
      sleep 10
    done
    echo "  NAT Gateway deleted."
  fi

  # Release NAT Elastic IP
  if [[ -n "${NAT_EIP_ALLOC_ID:-}" ]]; then
    delete_resource "NAT Elastic IP ${NAT_EIP_ALLOC_ID}" \
      aws ec2 release-address --allocation-id "$NAT_EIP_ALLOC_ID" --region "$region"
  fi

  # Disassociate route tables
  if [[ -n "${PRIVATE_RTA_ID:-}" ]]; then
    delete_resource "private route table association" \
      aws ec2 disassociate-route-table --association-id "$PRIVATE_RTA_ID" --region "$region"
  fi
  if [[ -n "${PUBLIC_RTA_ID:-}" ]]; then
    delete_resource "public route table association" \
      aws ec2 disassociate-route-table --association-id "$PUBLIC_RTA_ID" --region "$region"
  fi

  # Delete route tables
  if [[ -n "${PRIVATE_RT_ID:-}" ]]; then
    delete_resource "private route table ${PRIVATE_RT_ID}" \
      aws ec2 delete-route-table --route-table-id "$PRIVATE_RT_ID" --region "$region"
  fi
  if [[ -n "${PUBLIC_RT_ID:-}" ]]; then
    delete_resource "public route table ${PUBLIC_RT_ID}" \
      aws ec2 delete-route-table --route-table-id "$PUBLIC_RT_ID" --region "$region"
  fi

  # Detach and delete Internet Gateway
  if [[ -n "${IGW_ID:-}" && -n "${VPC_ID:-}" ]]; then
    delete_resource "Internet Gateway attachment" \
      aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$region"
    delete_resource "Internet Gateway ${IGW_ID}" \
      aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$region"
  fi

  # Delete subnets
  if [[ -n "${PRIVATE_SUBNET_ID:-}" ]]; then
    delete_resource "private subnet ${PRIVATE_SUBNET_ID}" \
      aws ec2 delete-subnet --subnet-id "$PRIVATE_SUBNET_ID" --region "$region"
  fi
  if [[ -n "${PUBLIC_SUBNET_ID:-}" ]]; then
    delete_resource "public subnet ${PUBLIC_SUBNET_ID}" \
      aws ec2 delete-subnet --subnet-id "$PUBLIC_SUBNET_ID" --region "$region"
  fi

  # Delete VPC
  if [[ -n "${VPC_ID:-}" ]]; then
    delete_resource "VPC ${VPC_ID}" \
      aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$region"
  fi
}

# ─── cleanup_s3 ───────────────────────────────────────────────────────────────
cleanup_s3() {
  local region="$1"

  if [[ -z "${S3_BUCKET_NAME:-}" ]]; then
    return 0
  fi

  log_step "Cleaning up S3 resources"

  # Empty bucket first
  echo -n "  Emptying bucket ${S3_BUCKET_NAME}... "
  aws s3 rm "s3://${S3_BUCKET_NAME}" --recursive --region "$region" 2>/dev/null || true
  echo "done."

  delete_resource "S3 bucket ${S3_BUCKET_NAME}" \
    aws s3api delete-bucket --bucket "$S3_BUCKET_NAME" --region "$region"
}

# ─── cleanup_all ──────────────────────────────────────────────────────────────
cleanup_all() {
  local region="$1"

  echo -e "${BOLD}${RED}=== quickec2 Cleanup ===${NC}"
  echo ""

  cleanup_ec2 "$region"
  cleanup_vpc "$region"
  cleanup_s3 "$region"

  # Remove generated files
  rm -f "${QUICKEC2_DIR}/user-data.sh"
  rm -f "$RESOURCES_FILE"

  echo ""
  log_success "All resources cleaned up. resources.env removed."
}
