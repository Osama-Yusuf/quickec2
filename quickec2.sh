#!/usr/bin/env bash
# quickec2 — Interactive AWS EC2 Deployment Boilerplate
# Usage: ./quickec2.sh [--dry-run] [--config <file>] [--status] [--connect] [--help]
set -euo pipefail
export AWS_PAGER=""

QUICKEC2_DIR="$(cd "$(dirname "$0")" && pwd)"
export QUICKEC2_DIR

# Source all libraries
source "${QUICKEC2_DIR}/lib/common.sh"
source "${QUICKEC2_DIR}/lib/prompt.sh"
source "${QUICKEC2_DIR}/lib/costs.sh"
source "${QUICKEC2_DIR}/lib/vpc.sh"
source "${QUICKEC2_DIR}/lib/s3.sh"
source "${QUICKEC2_DIR}/lib/software.sh"
source "${QUICKEC2_DIR}/lib/ec2.sh"
source "${QUICKEC2_DIR}/lib/cleanup.sh"

# ─── CLI Flags ────────────────────────────────────────────────────────────────
DRY_RUN="false"
CONFIG_INPUT=""
ACTION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --config)
      CONFIG_INPUT="${2:-}"
      [[ -z "$CONFIG_INPUT" ]] && die "--config requires a file path"
      shift 2
      ;;
    --profile)
      export AWS_PROFILE="${2:-}"
      [[ -z "$AWS_PROFILE" ]] && die "--profile requires a profile name"
      shift 2
      ;;
    --status)
      ACTION="status"
      shift
      ;;
    --connect)
      ACTION="connect"
      shift
      ;;
    --help|-h)
      ACTION="help"
      shift
      ;;
    *)
      die "Unknown option: $1. Use --help for usage."
      ;;
  esac
done

export DRY_RUN

# ─── Help ─────────────────────────────────────────────────────────────────────
show_help() {
  cat << 'EOF'
quickec2 — Interactive AWS EC2 Deployment Boilerplate

Usage:
  ./quickec2.sh                        Interactive deployment
  ./quickec2.sh --dry-run              Full prompt flow, print commands, create nothing
  ./quickec2.sh --config <file>        Deploy from saved config (skip prompts)
  ./quickec2.sh --profile <name>       Use a specific AWS CLI profile
  ./quickec2.sh --status               Show instance state and SSM status
  ./quickec2.sh --connect              Connect via SSM (private) or SSH (public)
  ./quickec2.sh --help                 Show this help

Cleanup:
  ./cleanup.sh                         Tear down all created resources

Options:
  --dry-run        Run through prompts, show config summary and cost estimate,
                   print all AWS commands with [DRY RUN] prefix, then exit.
  --config FILE    Load a previously saved quickec2.conf and deploy without
                   interactive prompts.
  --profile NAME   Use a named AWS CLI profile (sets AWS_PROFILE).
  --status         Read resources.env and display current instance state,
                   public IP, and SSM agent status.
  --connect        Auto-detect connection method:
                   - Private mode: aws ssm start-session
                   - Public mode:  ssh -i key user@ip
  --help           Show this help message.
EOF
}

# ─── Status ───────────────────────────────────────────────────────────────────
show_status() {
  if ! load_resources; then
    die "No resources.env found. Nothing deployed."
  fi

  local region="${AWS_REGION:-eu-west-1}"
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    region="${AWS_REGION:-$region}"
  fi

  echo -e "\n${BOLD}=== quickec2 Status ===${NC}\n"

  if [[ -n "${INSTANCE_ID:-}" ]]; then
    local state
    state=$(aws ec2 describe-instances \
      --instance-ids "$INSTANCE_ID" \
      --region "$region" \
      --query 'Reservations[0].Instances[0].State.Name' \
      --output text 2>/dev/null || echo "unknown")
    echo -e "  Instance:  ${CYAN}${INSTANCE_ID}${NC} (${state})"

    # Public IP
    local ip
    ip=$(aws ec2 describe-instances \
      --instance-ids "$INSTANCE_ID" \
      --region "$region" \
      --query 'Reservations[0].Instances[0].PublicIpAddress' \
      --output text 2>/dev/null || echo "None")
    if [[ "$ip" != "None" ]]; then
      echo -e "  Public IP: ${CYAN}${ip}${NC}"
    fi

    # SSM status
    local ssm_status
    ssm_status=$(aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
      --region "$region" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null || echo "Unknown")
    echo -e "  SSM:       ${CYAN}${ssm_status}${NC}"
  fi

  echo -e "  Region:    ${CYAN}${region}${NC}"
  echo -e "  Network:   ${CYAN}${NETWORK_MODE:-unknown}${NC}"
  [[ -n "${VPC_ID:-}" ]]          && echo -e "  VPC:       ${CYAN}${VPC_ID}${NC}"
  [[ -n "${S3_BUCKET_NAME:-}" ]]  && echo -e "  S3:        ${CYAN}${S3_BUCKET_NAME}${NC}"
  echo ""
}

# ─── Connect ──────────────────────────────────────────────────────────────────
do_connect() {
  if ! load_resources; then
    die "No resources.env found. Nothing deployed."
  fi

  local region="${AWS_REGION:-eu-west-1}"
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    region="${AWS_REGION:-$region}"
  fi

  if [[ -z "${INSTANCE_ID:-}" ]]; then
    die "No instance ID found in resources.env"
  fi

  local mode="${NETWORK_MODE:-private}"

  if [[ "$mode" == "private" ]]; then
    log_info "Connecting via SSM to ${INSTANCE_ID}..."
    exec aws ssm start-session --target "$INSTANCE_ID" --region "$region"
  else
    # Public mode — try SSH first, fall back to SSM
    local ip="${EC2_PUBLIC_IP:-}"
    if [[ -z "$ip" || "$ip" == "None" ]]; then
      ip=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$region" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text 2>/dev/null || echo "")
    fi

    local os="${OS_TYPE:-al2023}"
    local default_user
    default_user=$(get_default_user)

    local key_file="${QUICKEC2_DIR}/${KEY_NAME:-}.pem"
    if [[ -n "${KEY_NAME:-}" && -f "$key_file" && -n "$ip" && "$ip" != "None" ]]; then
      log_info "Connecting via SSH to ${default_user}@${ip}..."
      exec ssh -i "$key_file" -o StrictHostKeyChecking=no "${default_user}@${ip}"
    else
      log_info "Connecting via SSM to ${INSTANCE_ID}..."
      exec aws ssm start-session --target "$INSTANCE_ID" --region "$region"
    fi
  fi
}

# ─── Handle non-deploy actions ────────────────────────────────────────────────
case "${ACTION}" in
  help)    show_help; exit 0 ;;
  status)  show_status; exit 0 ;;
  connect) do_connect; exit 0 ;;
esac

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}  quickec2 — Interactive AWS EC2 Deployment${NC}"
if [[ "$DRY_RUN" == "true" ]]; then
  echo -e "  ${DIM}(dry-run mode — no resources will be created)${NC}"
fi
echo ""

# ─── AWS Profile (prompt if not set via --profile or config) ──────────────────
if [[ -z "${AWS_PROFILE:-}" ]]; then
  if [[ -n "$CONFIG_INPUT" ]]; then
    # Peek into config for profile before full load
    local_profile=$(grep '^AWS_PROFILE=' "$CONFIG_INPUT" 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "")
    if [[ -n "$local_profile" ]]; then
      export AWS_PROFILE="$local_profile"
    fi
  fi
  if [[ -z "${AWS_PROFILE:-}" ]]; then
    echo -e "${BOLD}AWS profile${NC} [${DIM}default${NC}]: \c"
    read -r profile_input
    export AWS_PROFILE="${profile_input:-default}"
  fi
fi
log_info "Using AWS profile: ${AWS_PROFILE}"

# ─── Prerequisites ────────────────────────────────────────────────────────────
check_prerequisites

# ─── Check for existing deployment ────────────────────────────────────────────
if [[ -f "$RESOURCES_FILE" && "$DRY_RUN" != "true" ]]; then
  echo ""
  log_warn "resources.env already exists from a previous deployment."
  log_warn "Run ./cleanup.sh first to tear down existing resources."
  read -rp "Continue anyway? (yes/no): " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
  rm -f "$RESOURCES_FILE"
fi

# ─── Interactive Prompts (or load config) ─────────────────────────────────────
if [[ -n "$CONFIG_INPUT" ]]; then
  log_step "Loading config from ${CONFIG_INPUT}"
  load_config "$CONFIG_INPUT"
else
  log_step "Configuration"
  echo ""

  # 1. Project name
  local_default=$(basename "$QUICKEC2_DIR")
  PROJECT_NAME=$(prompt_input "Project name" "$local_default")

  # 2. AWS Region
  AWS_REGION=$(prompt_input "AWS Region" "eu-west-1")

  # 3. Network mode
  NETWORK_MODE=$(prompt_select "Network mode" "private" "public" "private")

  # 4-5. Public-only options
  IP_TYPE="auto"
  INBOUND_PORTS=""
  KEY_PAIR_OPTION="none"
  EXISTING_KEY_NAME=""
  if [[ "$NETWORK_MODE" == "public" ]]; then
    IP_TYPE=$(prompt_select "IP type" "auto" "auto" "elastic")
    INBOUND_PORTS=$(prompt_ports "Inbound ports" "22,80,443")
  fi

  # 6. Instance type
  INSTANCE_TYPE=$(prompt_select "Instance type" "t3.micro" \
    "t3.nano" "t3.micro" "t3.small" "t3.medium" "t3.large")

  # 7. Operating system
  OS_TYPE=$(prompt_select "Operating system" "al2023" \
    "al2023" "ubuntu2204" "ubuntu2404")

  # 8. Volume size
  VOLUME_SIZE=$(prompt_input "Volume size (GB)" "20")

  # 9. Volume type
  VOLUME_TYPE=$(prompt_select "Volume type" "gp3" "gp3" "gp2" "io1")

  # 10. SSH key pair (public only)
  if [[ "$NETWORK_MODE" == "public" ]]; then
    KEY_PAIR_OPTION=$(prompt_select "SSH key pair" "create" "create" "existing" "none")
    if [[ "$KEY_PAIR_OPTION" == "existing" ]]; then
      EXISTING_KEY_NAME=$(prompt_input "Existing key pair name" "")
    fi
  fi

  # 11. Software
  SOFTWARE=$(prompt_multiselect "Software to install" "docker,git" \
    "docker" "git" "nodejs" "python" "nginx" "certbot")

  # 12. Node.js version (if selected)
  NODE_VERSION=""
  if [[ "$SOFTWARE" == *"nodejs"* ]]; then
    NODE_VERSION=$(prompt_select "Node.js version" "20" "18" "20" "22")
  fi

  # 13. Python version (if selected)
  PYTHON_VERSION=""
  if [[ "$SOFTWARE" == *"python"* ]]; then
    PYTHON_VERSION=$(prompt_select "Python version" "3.12" "3.11" "3.12")
  fi

  # 14. S3 bucket
  CREATE_S3=$(prompt_confirm "Create S3 bucket?" "no") || true

  # 15. Bucket name (if yes)
  S3_BUCKET_NAME=""
  if [[ "$CREATE_S3" == "yes" ]]; then
    local default_bucket="${PROJECT_NAME}-${AWS_ACCOUNT_ID:-000000000000}"
    S3_BUCKET_NAME=$(prompt_input "Bucket name" "$default_bucket")
  fi
fi

# ─── Config summary + cost table ──────────────────────────────────────────────
print_summary
print_cost_table "$INSTANCE_TYPE" "$NETWORK_MODE" "$IP_TYPE" "$VOLUME_SIZE" "$VOLUME_TYPE" "$CREATE_S3"

# ─── Confirm ──────────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" != "true" ]]; then
  read -rp "$(echo -e "${BOLD}Proceed with deployment? (yes/no):${NC} ")" confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
  echo ""
fi

# ─── Dry-run exit point ──────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  echo -e "${BOLD}=== Dry Run — AWS Commands ===${NC}"
  echo ""
fi

# ─── 7. S3 bucket (if selected) ──────────────────────────────────────────────
if [[ "$CREATE_S3" == "yes" ]]; then
  create_s3_bucket "$S3_BUCKET_NAME" "$AWS_REGION" "$PROJECT_NAME"
fi

# ─── 8. VPC + networking ─────────────────────────────────────────────────────
create_vpc "$PROJECT_NAME" "$AWS_REGION" "$NETWORK_MODE"

# ─── 9. Generate user-data.sh ────────────────────────────────────────────────
generate_user_data "$OS_TYPE" "$SOFTWARE" "${NODE_VERSION:-}" "${PYTHON_VERSION:-}" "$USER_DATA_FILE"

# ─── 10. IAM role + security group ───────────────────────────────────────────
create_iam_role "$PROJECT_NAME" "$AWS_REGION" "$CREATE_S3" "${S3_BUCKET_NAME:-}"
create_security_group "$PROJECT_NAME" "$AWS_REGION" "$VPC_ID" "$NETWORK_MODE" "${INBOUND_PORTS:-}"

# ─── 11. Find AMI ────────────────────────────────────────────────────────────
find_ami "$OS_TYPE" "$AWS_REGION"

# ─── 12. Key pair (public only) ──────────────────────────────────────────────
KEY_NAME=""
if [[ "$NETWORK_MODE" == "public" ]]; then
  create_key_pair "$PROJECT_NAME" "$AWS_REGION" "$KEY_PAIR_OPTION" "${EXISTING_KEY_NAME:-}"
fi

# ─── 13. Launch EC2 ──────────────────────────────────────────────────────────
launch_instance \
  "$PROJECT_NAME" \
  "$AWS_REGION" \
  "$INSTANCE_TYPE" \
  "$EC2_SUBNET_ID" \
  "$SG_ID" \
  "${PROJECT_NAME}-${PROFILE_SUFFIX}" \
  "$AMI_ID" \
  "$VOLUME_SIZE" \
  "$VOLUME_TYPE" \
  "$OS_TYPE" \
  "${KEY_NAME:-}" \
  "$USER_DATA_FILE"

# ─── 14. Elastic IP (public + elastic) ───────────────────────────────────────
EC2_PUBLIC_IP=""
if [[ "$NETWORK_MODE" == "public" ]]; then
  if [[ "$IP_TYPE" == "elastic" ]]; then
    assign_eip "$INSTANCE_ID" "$AWS_REGION" "$PROJECT_NAME"
    EC2_PUBLIC_IP="${EC2_PUBLIC_IP:-}"
  else
    EC2_PUBLIC_IP=$(get_public_ip "$INSTANCE_ID" "$AWS_REGION")
    save_resource "EC2_PUBLIC_IP" "$EC2_PUBLIC_IP"
  fi
fi

# ─── 15. Wait SSM ────────────────────────────────────────────────────────────
wait_ssm "$INSTANCE_ID" "$AWS_REGION"

# ─── 16. Save config ─────────────────────────────────────────────────────────
if [[ "$DRY_RUN" != "true" ]]; then
  save_config
fi

# ─── 17. Print connection info ────────────────────────────────────────────────
print_connection_info \
  "$PROJECT_NAME" \
  "$AWS_REGION" \
  "$NETWORK_MODE" \
  "$INSTANCE_ID" \
  "$OS_TYPE" \
  "${KEY_NAME:-}" \
  "${EC2_PUBLIC_IP:-}"

if [[ "$DRY_RUN" == "true" ]]; then
  echo -e "${BOLD}${GREEN}Dry run complete. No resources were created.${NC}"
  echo ""
fi
