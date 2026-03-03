#!/usr/bin/env bash
# quickec2 — cost estimation

# Monthly EC2 on-demand prices (us-east-1 / eu-west-1 approximate)
get_instance_cost() {
  case "$1" in
    t3.nano)   echo "3.80" ;;
    t3.micro)  echo "7.59" ;;
    t3.small)  echo "15.18" ;;
    t3.medium) echo "30.37" ;;
    t3.large)  echo "60.74" ;;
    *)         echo "7.59" ;;
  esac
}

# Monthly EBS cost per GB
get_ebs_cost_per_gb() {
  case "$1" in
    gp3) echo "0.08" ;;
    gp2) echo "0.10" ;;
    io1) echo "0.125" ;;
    *)   echo "0.08" ;;
  esac
}

# ─── print_cost_table ─────────────────────────────────────────────────────────
print_cost_table() {
  local instance_type="$1"
  local network_mode="$2"
  local ip_type="$3"
  local volume_size="$4"
  local volume_type="$5"
  local create_s3="$6"

  local ec2_cost nat_cost ebs_cost eip_cost s3_cost total

  ec2_cost=$(get_instance_cost "$instance_type")
  ebs_cost=$(awk "BEGIN { printf \"%.2f\", $volume_size * $(get_ebs_cost_per_gb "$volume_type") }")

  nat_cost="0.00"
  if [[ "$network_mode" == "private" ]]; then
    nat_cost="32.40"
  fi

  eip_cost="0.00"
  if [[ "$ip_type" == "elastic" ]]; then
    eip_cost="3.65"
  fi

  s3_cost="0.00"
  if [[ "$create_s3" == "yes" ]]; then
    s3_cost="0.01"
  fi

  total=$(awk "BEGIN { printf \"%.2f\", $ec2_cost + $nat_cost + $ebs_cost + $eip_cost + $s3_cost }")

  echo ""
  echo -e "${BOLD}=== Estimated Monthly Cost ===${NC}"
  printf "  %-25s %10s\n" "EC2 ($instance_type)" "\$${ec2_cost}"
  printf "  %-25s %10s\n" "EBS (${volume_size}GB $volume_type)" "\$${ebs_cost}"
  if [[ "$network_mode" == "private" ]]; then
    printf "  %-25s %10s\n" "NAT Gateway" "\$${nat_cost}"
  fi
  if [[ "$ip_type" == "elastic" ]]; then
    printf "  %-25s %10s\n" "Elastic IP" "\$${eip_cost}"
  fi
  if [[ "$create_s3" == "yes" ]]; then
    printf "  %-25s %10s\n" "S3 bucket (minimal)" "\$${s3_cost}"
  fi
  echo "  ─────────────────────────────────────"
  printf "  ${BOLD}%-25s %10s${NC}\n" "TOTAL (approx)" "\$${total}/mo"
  echo ""
}
