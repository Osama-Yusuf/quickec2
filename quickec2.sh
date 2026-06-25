#!/usr/bin/env bash
# quickec2 — AWS EC2 Deployment Boilerplate (interactive & non-interactive)
# Usage: ./quickec2.sh [flags]   — see --help for details
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
AUTO_APPROVE="false"

# Non-interactive overrides (empty = not set = prompt)
CLI_NAME=""
CLI_REGION=""
CLI_NETWORK=""
CLI_TYPE=""
CLI_OS=""
CLI_VOLUME_SIZE=""
CLI_VOLUME_TYPE=""
CLI_SOFTWARE=""
CLI_IP_TYPE=""
CLI_PORTS=""
CLI_KEY_PAIR=""
CLI_EXISTING_KEY=""
CLI_NODE_VERSION=""
CLI_PYTHON_VERSION=""
CLI_S3=""
CLI_S3_BUCKET=""

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
    --name)
      CLI_NAME="${2:-}"
      [[ -z "$CLI_NAME" ]] && die "--name requires a value"
      shift 2
      ;;
    --region)
      CLI_REGION="${2:-}"
      [[ -z "$CLI_REGION" ]] && die "--region requires a value"
      shift 2
      ;;
    --network)
      CLI_NETWORK="${2:-}"
      [[ -z "$CLI_NETWORK" ]] && die "--network requires a value (public or private)"
      shift 2
      ;;
    --type)
      CLI_TYPE="${2:-}"
      [[ -z "$CLI_TYPE" ]] && die "--type requires a value"
      shift 2
      ;;
    --os)
      CLI_OS="${2:-}"
      [[ -z "$CLI_OS" ]] && die "--os requires a value (al2023, ubuntu2204, ubuntu2404)"
      shift 2
      ;;
    --volume-size)
      CLI_VOLUME_SIZE="${2:-}"
      [[ -z "$CLI_VOLUME_SIZE" ]] && die "--volume-size requires a value"
      shift 2
      ;;
    --volume-type)
      CLI_VOLUME_TYPE="${2:-}"
      [[ -z "$CLI_VOLUME_TYPE" ]] && die "--volume-type requires a value (gp3, gp2, io1)"
      shift 2
      ;;
    --software)
      CLI_SOFTWARE="${2:-}"
      [[ -z "$CLI_SOFTWARE" ]] && die "--software requires a value (comma-separated: docker,git,nodejs,python,nginx,certbot)"
      shift 2
      ;;
    --ip-type)
      CLI_IP_TYPE="${2:-}"
      [[ -z "$CLI_IP_TYPE" ]] && die "--ip-type requires a value (auto or elastic)"
      shift 2
      ;;
    --ports)
      CLI_PORTS="${2:-}"
      [[ -z "$CLI_PORTS" ]] && die "--ports requires a value (comma-separated port numbers)"
      shift 2
      ;;
    --key-pair)
      CLI_KEY_PAIR="${2:-}"
      [[ -z "$CLI_KEY_PAIR" ]] && die "--key-pair requires a value (create, existing, none)"
      shift 2
      ;;
    --existing-key)
      CLI_EXISTING_KEY="${2:-}"
      [[ -z "$CLI_EXISTING_KEY" ]] && die "--existing-key requires a value"
      shift 2
      ;;
    --node-version)
      CLI_NODE_VERSION="${2:-}"
      [[ -z "$CLI_NODE_VERSION" ]] && die "--node-version requires a value"
      shift 2
      ;;
    --python-version)
      CLI_PYTHON_VERSION="${2:-}"
      [[ -z "$CLI_PYTHON_VERSION" ]] && die "--python-version requires a value"
      shift 2
      ;;
    --s3)
      CLI_S3="yes"
      shift
      ;;
    --s3-bucket)
      CLI_S3_BUCKET="${2:-}"
      [[ -z "$CLI_S3_BUCKET" ]] && die "--s3-bucket requires a value"
      CLI_S3="yes"
      shift 2
      ;;
    --yes|-y)
      AUTO_APPROVE="true"
      shift
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

# Detect non-interactive mode: if any deployment flags were passed, skip prompts for those
has_cli_overrides() {
  [[ -n "$CLI_REGION" || -n "$CLI_TYPE" || -n "$CLI_OS" || -n "$CLI_NETWORK" || -n "$CLI_SOFTWARE" || -n "$CLI_NAME" || -n "$CLI_VOLUME_SIZE" || -n "$CLI_VOLUME_TYPE" ]]
}
NON_INTERACTIVE="false"
if has_cli_overrides; then
  NON_INTERACTIVE="true"
fi

# ─── Help ─────────────────────────────────────────────────────────────────────
show_help() {
  cat << 'EOF'
quickec2 — AWS EC2 Deployment Boilerplate

Usage:
  ./quickec2.sh                        Interactive deployment (prompts for everything)
  ./quickec2.sh [flags] [-y]           Non-interactive deployment (flags set values, defaults fill the rest)
  ./quickec2.sh --config <file>        Deploy from saved config
  ./quickec2.sh --status               Show instance state and SSM status
  ./quickec2.sh --connect              Connect via SSM (private) or SSH (public)
  ./quickec2.sh --help                 Show this help

Deployment flags:
  --name NAME              Project name (default: directory name)
  --region REGION          AWS region (default: eu-west-1)
  --network MODE           private or public (default: private)
  --type TYPE              Instance type (default: t3.micro)
  --os OS                  al2023, ubuntu2204, ubuntu2404 (default: al2023)
  --volume-size GB         Root volume size in GB (default: 20)
  --volume-type TYPE       gp3, gp2, io1 (default: gp3)
  --software LIST          Comma-separated: docker,git,nodejs,python,nginx,certbot
  --ip-type TYPE           auto or elastic (public only, default: auto)
  --ports LIST             Inbound ports, comma-separated (public only, default: 22,80,443)
  --key-pair OPTION        create, existing, none (public only, default: create)
  --existing-key NAME      Existing key pair name (with --key-pair existing)
  --node-version VER       18, 20, 22 (default: 20)
  --python-version VER     3.11, 3.12 (default: 3.12)
  --s3                     Create an S3 bucket
  --s3-bucket NAME         Bucket name (implies --s3)

General flags:
  --profile NAME           AWS CLI profile
  --config FILE            Load saved config, skip all prompts
  --dry-run                Show config + costs, print AWS commands, exit
  --yes, -y                Skip confirmation prompt
  --status                 Show instance state, IP, SSM status
  --connect                Auto-detect: SSM (private) or SSH (public)
  --help, -h               Show this help

Cleanup:
  ./cleanup.sh [--profile NAME]        Tear down all created resources
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
if [[ "$NON_INTERACTIVE" == "true" ]]; then
  echo -e "${BOLD}${CYAN}  quickec2 — Non-Interactive AWS EC2 Deployment${NC}"
else
  echo -e "${BOLD}${CYAN}  quickec2 — Interactive AWS EC2 Deployment${NC}"
fi
if [[ "$DRY_RUN" == "true" ]]; then
  echo -e "  ${DIM}(dry-run mode — no resources will be created)${NC}"
fi
echo ""

# ─── AWS Profile (prompt if not set via --profile or config) ──────────────────
if [[ -z "${AWS_PROFILE:-}" ]]; then
  if [[ -n "$CONFIG_INPUT" ]]; then
    local_profile=$(grep '^AWS_PROFILE=' "$CONFIG_INPUT" 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "")
    if [[ -n "$local_profile" ]]; then
      export AWS_PROFILE="$local_profile"
    fi
  fi
  if [[ -z "${AWS_PROFILE:-}" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      export AWS_PROFILE="default"
    else
      echo -e "${BOLD}AWS profile${NC} [${DIM}default${NC}]: \c"
      read -r profile_input
      export AWS_PROFILE="${profile_input:-default}"
    fi
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
  if [[ "$AUTO_APPROVE" == "true" ]]; then
    log_info "Auto-approved: removing old resources.env"
    rm -f "$RESOURCES_FILE"
  else
    read -rp "Continue anyway? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
      echo "Aborted."
      exit 0
    fi
    rm -f "$RESOURCES_FILE"
  fi
fi

# ─── Configuration (config file > CLI flags > interactive prompts) ────────────
if [[ -n "$CONFIG_INPUT" ]]; then
  log_step "Loading config from ${CONFIG_INPUT}"
  load_config "$CONFIG_INPUT"
elif [[ "$NON_INTERACTIVE" == "true" ]]; then
  log_step "Configuration (non-interactive)"

  local_default=$(basename "$QUICKEC2_DIR")
  PROJECT_NAME="${CLI_NAME:-$local_default}"
  AWS_REGION="${CLI_REGION:-eu-west-1}"
  NETWORK_MODE="${CLI_NETWORK:-private}"

  IP_TYPE="${CLI_IP_TYPE:-auto}"
  INBOUND_PORTS="${CLI_PORTS:-}"
  KEY_PAIR_OPTION="none"
  EXISTING_KEY_NAME=""
  if [[ "$NETWORK_MODE" == "public" ]]; then
    INBOUND_PORTS="${CLI_PORTS:-22,80,443}"
    KEY_PAIR_OPTION="${CLI_KEY_PAIR:-create}"
    if [[ "$KEY_PAIR_OPTION" == "existing" ]]; then
      EXISTING_KEY_NAME="${CLI_EXISTING_KEY:-}"
      [[ -z "$EXISTING_KEY_NAME" ]] && die "--existing-key is required when --key-pair is existing"
    fi
  fi

  INSTANCE_TYPE="${CLI_TYPE:-t3.micro}"
  OS_TYPE="${CLI_OS:-al2023}"
  VOLUME_SIZE="${CLI_VOLUME_SIZE:-20}"
  VOLUME_TYPE="${CLI_VOLUME_TYPE:-gp3}"
  SOFTWARE="${CLI_SOFTWARE:-docker,git}"

  NODE_VERSION=""
  if [[ "$SOFTWARE" == *"nodejs"* ]]; then
    NODE_VERSION="${CLI_NODE_VERSION:-20}"
  fi

  PYTHON_VERSION=""
  if [[ "$SOFTWARE" == *"python"* ]]; then
    PYTHON_VERSION="${CLI_PYTHON_VERSION:-3.12}"
  fi

  CREATE_S3="${CLI_S3:-no}"
  S3_BUCKET_NAME=""
  if [[ "$CREATE_S3" == "yes" ]]; then
    S3_BUCKET_NAME="${CLI_S3_BUCKET:-${PROJECT_NAME}-${AWS_ACCOUNT_ID:-000000000000}}"
  fi
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
if [[ "$DRY_RUN" != "true" && "$AUTO_APPROVE" != "true" ]]; then
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
