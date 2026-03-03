#!/usr/bin/env bash
# quickec2 — IAM role, security group, AMI, key pair, EC2 launch, EIP, SSM wait

ROLE_SUFFIX="ec2-role"
PROFILE_SUFFIX="ec2-profile"

# ─── create_iam_role ──────────────────────────────────────────────────────────
create_iam_role() {
  local project="$1"
  local region="$2"
  local create_s3="$3"
  local bucket_name="${4:-}"

  local role_name="${project}-${ROLE_SUFFIX}"
  local profile_name="${project}-${PROFILE_SUFFIX}"

  log_step "Creating IAM role and instance profile"

  # Trust policy
  local trust_policy='{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": { "Service": "ec2.amazonaws.com" },
        "Action": "sts:AssumeRole"
      }
    ]
  }'

  log_info "Creating IAM role: ${role_name}..."
  aws_cmd iam create-role \
    --role-name "$role_name" \
    --assume-role-policy-document "$trust_policy" \
    --tags "Key=Name,Value=${role_name}" "Key=CreatedBy,Value=quickec2" \
    > /dev/null
  save_resource "ROLE_NAME" "$role_name"

  # Attach SSM managed policy
  aws_cmd iam attach-role-policy \
    --role-name "$role_name" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" \
    > /dev/null 2>&1 || true
  log_success "Attached SSM policy"

  # S3 inline policy if bucket is created
  if [[ "$create_s3" == "yes" && -n "$bucket_name" ]]; then
    local s3_policy
    s3_policy="{
      \"Version\": \"2012-10-17\",
      \"Statement\": [
        {
          \"Effect\": \"Allow\",
          \"Action\": [\"s3:GetObject\", \"s3:PutObject\", \"s3:ListBucket\", \"s3:DeleteObject\"],
          \"Resource\": [
            \"arn:aws:s3:::${bucket_name}\",
            \"arn:aws:s3:::${bucket_name}/*\"
          ]
        }
      ]
    }"

    aws_cmd iam put-role-policy \
      --role-name "$role_name" \
      --policy-name "${project}-s3-access" \
      --policy-document "$s3_policy" \
      > /dev/null 2>&1 || true
    log_success "Attached S3 inline policy for ${bucket_name}"
  fi

  # Instance profile
  log_info "Creating instance profile: ${profile_name}..."
  aws_cmd iam create-instance-profile \
    --instance-profile-name "$profile_name" \
    > /dev/null
  save_resource "INSTANCE_PROFILE_NAME" "$profile_name"

  aws_cmd iam add-role-to-instance-profile \
    --instance-profile-name "$profile_name" \
    --role-name "$role_name" \
    > /dev/null 2>&1 || true

  # Wait for instance profile to propagate
  if [[ "$DRY_RUN" != "true" ]]; then
    log_info "Waiting for instance profile to propagate..."
    sleep 10
  fi
  log_success "Instance profile: ${profile_name}"
}

# ─── create_security_group ────────────────────────────────────────────────────
create_security_group() {
  local project="$1"
  local region="$2"
  local vpc_id="$3"
  local network_mode="$4"
  local inbound_ports="${5:-}"

  log_step "Creating security group"

  local sg_name="${project}-sg"

  SG_ID=$(aws_cmd ec2 create-security-group \
    --group-name "$sg_name" \
    --description "quickec2 security group for ${project}" \
    --vpc-id "$vpc_id" \
    --region "$region" \
    --query 'GroupId' \
    --output text)
  save_resource "SG_ID" "$SG_ID"
  tag_resource "$SG_ID" "$sg_name" "$region"

  if [[ "$network_mode" == "private" ]]; then
    # Private mode: revoke default egress, allow only HTTP/HTTPS outbound
    aws_cmd ec2 revoke-security-group-egress \
      --group-id "$SG_ID" \
      --ip-permissions '[{"IpProtocol":"-1","FromPort":-1,"ToPort":-1,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' \
      --region "$region" > /dev/null 2>&1 || true

    aws_cmd ec2 authorize-security-group-egress \
      --group-id "$SG_ID" \
      --ip-permissions \
        '[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"HTTPS outbound"}]},{"IpProtocol":"tcp","FromPort":80,"ToPort":80,"IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"HTTP outbound"}]}]' \
      --region "$region" > /dev/null 2>&1 || true
    log_success "Security group: ${SG_ID} (outbound 80/443 only, no inbound)"
  else
    # Public mode: add user-specified inbound ports
    if [[ -n "$inbound_ports" ]]; then
      IFS=',' read -ra ports <<< "$inbound_ports"
      for port in "${ports[@]}"; do
        port="$(echo "$port" | xargs)"
        aws_cmd ec2 authorize-security-group-ingress \
          --group-id "$SG_ID" \
          --protocol tcp \
          --port "$port" \
          --cidr "0.0.0.0/0" \
          --region "$region" > /dev/null 2>&1 || true
      done
    fi
    log_success "Security group: ${SG_ID} (inbound: ${inbound_ports:-none}, all outbound)"
  fi
}

# ─── find_ami ─────────────────────────────────────────────────────────────────
find_ami() {
  local os_type="$1"
  local region="$2"

  log_step "Finding latest AMI"

  local owner pattern
  owner=$(get_ami_owner)
  pattern=$(get_ami_pattern)

  log_info "Looking for ${os_type} AMI (${pattern})..."
  AMI_ID=$(aws_cmd ec2 describe-images \
    --owners "$owner" \
    --filters \
      "Name=name,Values=${pattern}" \
      "Name=state,Values=available" \
      "Name=architecture,Values=x86_64" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --region "$region" \
    --output text)

  if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
    die "No AMI found for ${os_type} in ${region}"
  fi

  save_resource "AMI_ID" "$AMI_ID"
  save_resource "OS_TYPE" "$os_type"
  log_success "AMI: ${AMI_ID}"
}

# ─── create_key_pair ──────────────────────────────────────────────────────────
create_key_pair() {
  local project="$1"
  local region="$2"
  local option="$3"        # create, existing, none
  local existing_name="${4:-}"

  if [[ "$option" == "none" ]]; then
    KEY_NAME=""
    return 0
  fi

  log_step "Setting up key pair"

  if [[ "$option" == "existing" ]]; then
    KEY_NAME="$existing_name"
    save_resource "KEY_NAME" "$KEY_NAME"
    save_resource "KEY_CREATED" "false"
    log_success "Using existing key: ${KEY_NAME}"
    return 0
  fi

  # Create new key pair
  KEY_NAME="${project}-key"
  local key_file="${QUICKEC2_DIR}/${KEY_NAME}.pem"

  log_info "Creating key pair: ${KEY_NAME}..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "aws ec2 create-key-pair --key-name ${KEY_NAME} ... > ${key_file}"
  else
    aws ec2 create-key-pair \
      --key-name "$KEY_NAME" \
      --query 'KeyMaterial' \
      --region "$region" \
      --output text > "$key_file"
    chmod 400 "$key_file"
  fi

  save_resource "KEY_NAME" "$KEY_NAME"
  save_resource "KEY_FILE" "$key_file"
  save_resource "KEY_CREATED" "true"
  log_success "Key pair: ${KEY_NAME} (saved to ${key_file})"
}

# ─── launch_instance ──────────────────────────────────────────────────────────
launch_instance() {
  local project="$1"
  local region="$2"
  local instance_type="$3"
  local subnet_id="$4"
  local sg_id="$5"
  local profile_name="$6"
  local ami_id="$7"
  local volume_size="$8"
  local volume_type="$9"
  local os_type="${10}"
  local key_name="${11:-}"
  local user_data_file="${12:-}"

  log_step "Launching EC2 instance"

  local root_device
  root_device=$(get_root_device)

  local block_device
  block_device="[{\"DeviceName\":\"${root_device}\",\"Ebs\":{\"VolumeSize\":${volume_size},\"VolumeType\":\"${volume_type}\"}}]"

  local cmd_args=(
    ec2 run-instances
    --image-id "$ami_id"
    --instance-type "$instance_type"
    --subnet-id "$subnet_id"
    --security-group-ids "$sg_id"
    --iam-instance-profile "Name=${profile_name}"
    --block-device-mappings "$block_device"
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${project}-ec2},{Key=CreatedBy,Value=quickec2},{Key=CreatedAt,Value=$(date -u +%Y-%m-%dT%H:%M:%SZ)}]"
    --region "$region"
    --query 'Instances[0].InstanceId'
    --output text
  )

  if [[ -n "$key_name" ]]; then
    cmd_args+=(--key-name "$key_name")
  fi

  if [[ -n "$user_data_file" && -f "$user_data_file" ]]; then
    cmd_args+=(--user-data "file://${user_data_file}")
  fi

  log_info "Launching ${instance_type} instance..."
  INSTANCE_ID=$(aws_cmd "${cmd_args[@]}")
  save_resource "INSTANCE_ID" "$INSTANCE_ID"
  log_success "Instance: ${INSTANCE_ID}"

  # Wait for instance to be running
  if [[ "$DRY_RUN" != "true" ]]; then
    log_info "Waiting for instance to start..."
    aws ec2 wait instance-running \
      --instance-ids "$INSTANCE_ID" \
      --region "$region"
    log_success "Instance is running"
  fi
}

# ─── assign_eip ───────────────────────────────────────────────────────────────
assign_eip() {
  local instance_id="$1"
  local region="$2"
  local project="$3"

  log_step "Assigning Elastic IP"

  EC2_EIP_ALLOC_ID=$(aws_cmd ec2 allocate-address \
    --domain vpc \
    --region "$region" \
    --query 'AllocationId' \
    --output text)
  save_resource "EC2_EIP_ALLOC_ID" "$EC2_EIP_ALLOC_ID"
  tag_resource "$EC2_EIP_ALLOC_ID" "${project}-ec2-eip" "$region"

  aws_cmd ec2 associate-address \
    --instance-id "$instance_id" \
    --allocation-id "$EC2_EIP_ALLOC_ID" \
    --region "$region" > /dev/null 2>&1 || true

  local eip_address
  if [[ "$DRY_RUN" == "true" ]]; then
    eip_address="1.2.3.4"
  else
    eip_address=$(aws ec2 describe-addresses \
      --allocation-ids "$EC2_EIP_ALLOC_ID" \
      --region "$region" \
      --query 'Addresses[0].PublicIp' \
      --output text)
  fi
  save_resource "EC2_PUBLIC_IP" "$eip_address"
  log_success "Elastic IP: ${eip_address}"
}

# ─── get_public_ip ────────────────────────────────────────────────────────────
get_public_ip() {
  local instance_id="$1"
  local region="$2"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "1.2.3.4"
    return
  fi

  aws ec2 describe-instances \
    --instance-ids "$instance_id" \
    --region "$region" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text
}

# ─── wait_ssm ─────────────────────────────────────────────────────────────────
wait_ssm() {
  local instance_id="$1"
  local region="$2"

  log_step "Waiting for SSM agent"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "Would poll SSM status for ${instance_id}"
    return 0
  fi

  log_info "Waiting for SSM agent to register (this may take 2-3 minutes)..."
  for i in $(seq 1 30); do
    local ssm_status
    ssm_status=$(aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=${instance_id}" \
      --region "$region" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null || echo "None")

    if [[ "$ssm_status" == "Online" ]]; then
      save_resource "SSM_STATUS" "Online"
      log_success "SSM agent is online!"
      return 0
    fi

    if [[ $i -eq 30 ]]; then
      log_warn "SSM agent not yet online after 5 minutes."
      log_warn "The instance may still be bootstrapping. Try: ./quickec2.sh --status"
      save_resource "SSM_STATUS" "Pending"
      return 0
    fi
    sleep 10
  done
}

# ─── print_connection_info ────────────────────────────────────────────────────
print_connection_info() {
  local project="$1"
  local region="$2"
  local network_mode="$3"
  local instance_id="$4"
  local os_type="$5"
  local key_name="${6:-}"
  local ip="${7:-}"

  local default_user
  default_user=$(get_default_user)

  echo ""
  echo -e "${BOLD}${GREEN}=== Deployment Complete ===${NC}"
  echo -e "  Instance ID:  ${CYAN}${instance_id}${NC}"
  echo -e "  Region:       ${CYAN}${region}${NC}"

  if [[ "$network_mode" == "private" ]]; then
    echo ""
    echo -e "  ${BOLD}Connect via SSM:${NC}"
    echo -e "  ${DIM}aws ssm start-session --target ${instance_id} --region ${region}${NC}"
    echo -e "  ${DIM}or: ./quickec2.sh --connect${NC}"
  else
    if [[ -n "$ip" && "$ip" != "None" ]]; then
      echo -e "  Public IP:    ${CYAN}${ip}${NC}"
    fi
    echo ""
    if [[ -n "$key_name" ]]; then
      local key_file="${QUICKEC2_DIR}/${key_name}.pem"
      echo -e "  ${BOLD}Connect via SSH:${NC}"
      echo -e "  ${DIM}ssh -i ${key_file} ${default_user}@${ip}${NC}"
    fi
    echo -e "  ${BOLD}Connect via SSM:${NC}"
    echo -e "  ${DIM}aws ssm start-session --target ${instance_id} --region ${region}${NC}"
    echo -e "  ${DIM}or: ./quickec2.sh --connect${NC}"
  fi

  echo ""
  echo -e "  ${BOLD}Check status:${NC}  ${DIM}./quickec2.sh --status${NC}"
  echo -e "  ${BOLD}Tear down:${NC}     ${DIM}./cleanup.sh${NC}"
  echo ""
}
