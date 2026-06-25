#!/usr/bin/env bash
# quickec2 — VPC, subnets, IGW, NAT, route tables

VPC_CIDR="10.0.0.0/16"
PUBLIC_SUBNET_CIDR="10.0.1.0/24"
PRIVATE_SUBNET_CIDR="10.0.2.0/24"

# ─── create_vpc ───────────────────────────────────────────────────────────────
create_vpc() {
  local project="$1"
  local region="$2"
  local mode="$3"   # public | private

  log_step "Creating VPC and networking (${mode} mode)"

  # VPC
  log_info "Creating VPC (${VPC_CIDR})..."
  VPC_ID=$(aws_cmd ec2 create-vpc \
    --cidr-block "$VPC_CIDR" \
    --region "$region" \
    --query 'Vpc.VpcId' \
    --output text)
  save_resource "VPC_ID" "$VPC_ID"
  tag_resource "$VPC_ID" "${project}-vpc" "$region"

  # Enable DNS hostnames
  aws_cmd ec2 modify-vpc-attribute \
    --vpc-id "$VPC_ID" \
    --enable-dns-hostnames '{"Value":true}' \
    --region "$region" > /dev/null 2>&1 || true
  log_success "VPC: ${VPC_ID}"

  # Default SGs allow all traffic between members + all outbound.
  # CIS AWS benchmark requires revoking these rules even if the SG is never used — best practice.
  local default_sg
  if [[ "$DRY_RUN" == "true" ]]; then
    default_sg="sg-dry-default"
    log_dry "aws ec2 describe-security-groups ... (get default SG)"
  else
    default_sg=$(aws ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=default" \
      --region "$region" \
      --query 'SecurityGroups[0].GroupId' \
      --output text)
  fi
  aws_cmd ec2 revoke-security-group-ingress \
    --group-id "$default_sg" \
    --ip-permissions '[{"IpProtocol":"-1","UserIdGroupPairs":[{"GroupId":"'"$default_sg"'"}]}]' \
    --region "$region" > /dev/null 2>&1 || true
  aws_cmd ec2 revoke-security-group-egress \
    --group-id "$default_sg" \
    --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' \
    --region "$region" > /dev/null 2>&1 || true
  log_success "Default security group locked down: ${default_sg}"

  # Internet Gateway
  log_info "Creating Internet Gateway..."
  IGW_ID=$(aws_cmd ec2 create-internet-gateway \
    --region "$region" \
    --query 'InternetGateway.InternetGatewayId' \
    --output text)
  save_resource "IGW_ID" "$IGW_ID"
  tag_resource "$IGW_ID" "${project}-igw" "$region"

  aws_cmd ec2 attach-internet-gateway \
    --internet-gateway-id "$IGW_ID" \
    --vpc-id "$VPC_ID" \
    --region "$region" > /dev/null 2>&1 || true
  log_success "IGW: ${IGW_ID}"

  # Get first AZ in region
  local az
  if [[ "$DRY_RUN" == "true" ]]; then
    az="${region}a"
  else
    az=$(aws ec2 describe-availability-zones \
      --region "$region" \
      --query 'AvailabilityZones[0].ZoneName' \
      --output text)
  fi
  save_resource "AZ" "$az"

  # Public subnet (always created — for NAT in private mode, for EC2 in public mode)
  log_info "Creating public subnet (${PUBLIC_SUBNET_CIDR})..."
  PUBLIC_SUBNET_ID=$(aws_cmd ec2 create-subnet \
    --vpc-id "$VPC_ID" \
    --cidr-block "$PUBLIC_SUBNET_CIDR" \
    --availability-zone "$az" \
    --region "$region" \
    --query 'Subnet.SubnetId' \
    --output text)
  save_resource "PUBLIC_SUBNET_ID" "$PUBLIC_SUBNET_ID"
  tag_resource "$PUBLIC_SUBNET_ID" "${project}-public-subnet" "$region"

  # Auto-assign public IPs on public subnet
  aws_cmd ec2 modify-subnet-attribute \
    --subnet-id "$PUBLIC_SUBNET_ID" \
    --map-public-ip-on-launch \
    --region "$region" > /dev/null 2>&1 || true
  log_success "Public subnet: ${PUBLIC_SUBNET_ID}"

  # Public route table
  log_info "Creating public route table..."
  PUBLIC_RT_ID=$(aws_cmd ec2 create-route-table \
    --vpc-id "$VPC_ID" \
    --region "$region" \
    --query 'RouteTable.RouteTableId' \
    --output text)
  save_resource "PUBLIC_RT_ID" "$PUBLIC_RT_ID"
  tag_resource "$PUBLIC_RT_ID" "${project}-public-rt" "$region"

  aws_cmd ec2 create-route \
    --route-table-id "$PUBLIC_RT_ID" \
    --destination-cidr-block "0.0.0.0/0" \
    --gateway-id "$IGW_ID" \
    --region "$region" > /dev/null 2>&1 || true

  PUBLIC_RTA_ID=$(aws_cmd ec2 associate-route-table \
    --route-table-id "$PUBLIC_RT_ID" \
    --subnet-id "$PUBLIC_SUBNET_ID" \
    --region "$region" \
    --query 'AssociationId' \
    --output text)
  save_resource "PUBLIC_RTA_ID" "$PUBLIC_RTA_ID"
  log_success "Public route table: ${PUBLIC_RT_ID}"

  # ─── Private mode: add private subnet + NAT ──────────────────────────────
  if [[ "$mode" == "private" ]]; then
    log_info "Creating private subnet (${PRIVATE_SUBNET_CIDR})..."
    PRIVATE_SUBNET_ID=$(aws_cmd ec2 create-subnet \
      --vpc-id "$VPC_ID" \
      --cidr-block "$PRIVATE_SUBNET_CIDR" \
      --availability-zone "$az" \
      --region "$region" \
      --query 'Subnet.SubnetId' \
      --output text)
    save_resource "PRIVATE_SUBNET_ID" "$PRIVATE_SUBNET_ID"
    tag_resource "$PRIVATE_SUBNET_ID" "${project}-private-subnet" "$region"
    log_success "Private subnet: ${PRIVATE_SUBNET_ID}"

    # Elastic IP for NAT
    log_info "Allocating Elastic IP for NAT Gateway..."
    NAT_EIP_ALLOC_ID=$(aws_cmd ec2 allocate-address \
      --domain vpc \
      --region "$region" \
      --query 'AllocationId' \
      --output text)
    save_resource "NAT_EIP_ALLOC_ID" "$NAT_EIP_ALLOC_ID"
    tag_resource "$NAT_EIP_ALLOC_ID" "${project}-nat-eip" "$region"
    log_success "NAT EIP: ${NAT_EIP_ALLOC_ID}"

    # NAT Gateway (in public subnet)
    log_info "Creating NAT Gateway (this takes 1-2 minutes)..."
    NAT_GW_ID=$(aws_cmd ec2 create-nat-gateway \
      --subnet-id "$PUBLIC_SUBNET_ID" \
      --allocation-id "$NAT_EIP_ALLOC_ID" \
      --region "$region" \
      --query 'NatGateway.NatGatewayId' \
      --output text)
    save_resource "NAT_GW_ID" "$NAT_GW_ID"
    tag_resource "$NAT_GW_ID" "${project}-nat" "$region"

    if [[ "$DRY_RUN" != "true" ]]; then
      aws ec2 wait nat-gateway-available \
        --nat-gateway-ids "$NAT_GW_ID" \
        --region "$region"
    fi
    log_success "NAT Gateway: ${NAT_GW_ID}"

    # Private route table
    log_info "Creating private route table..."
    PRIVATE_RT_ID=$(aws_cmd ec2 create-route-table \
      --vpc-id "$VPC_ID" \
      --region "$region" \
      --query 'RouteTable.RouteTableId' \
      --output text)
    save_resource "PRIVATE_RT_ID" "$PRIVATE_RT_ID"
    tag_resource "$PRIVATE_RT_ID" "${project}-private-rt" "$region"

    aws_cmd ec2 create-route \
      --route-table-id "$PRIVATE_RT_ID" \
      --destination-cidr-block "0.0.0.0/0" \
      --nat-gateway-id "$NAT_GW_ID" \
      --region "$region" > /dev/null 2>&1 || true

    PRIVATE_RTA_ID=$(aws_cmd ec2 associate-route-table \
      --route-table-id "$PRIVATE_RT_ID" \
      --subnet-id "$PRIVATE_SUBNET_ID" \
      --region "$region" \
      --query 'AssociationId' \
      --output text)
    save_resource "PRIVATE_RTA_ID" "$PRIVATE_RTA_ID"
    log_success "Private route table: ${PRIVATE_RT_ID}"
  fi

  # Export the subnet ID where EC2 will be placed
  if [[ "$mode" == "private" ]]; then
    EC2_SUBNET_ID="$PRIVATE_SUBNET_ID"
  else
    EC2_SUBNET_ID="$PUBLIC_SUBNET_ID"
  fi
  save_resource "EC2_SUBNET_ID" "$EC2_SUBNET_ID"
  save_resource "NETWORK_MODE" "$mode"
}
