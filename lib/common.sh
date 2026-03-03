#!/usr/bin/env bash
# quickec2 — common utilities
# Colors, logging, aws_cmd wrapper, resource tracking, tagging

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Logging
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "\n${BOLD}${CYAN}=> $*${NC}"; }
log_dry()     { echo -e "${DIM}[DRY RUN]${NC} $*"; }

# Die with error message
die() { log_error "$@"; exit 1; }

# Resolve SCRIPT_DIR relative to the main quickec2.sh
resolve_script_dir() {
  local source="${BASH_SOURCE[1]:-$0}"
  local dir
  dir="$(cd -P "$(dirname "$source")" && pwd)"
  echo "$dir"
}

# Paths — set by main script, defaults here
QUICKEC2_DIR="${QUICKEC2_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RESOURCES_FILE="${QUICKEC2_DIR}/resources.env"
CONFIG_FILE="${QUICKEC2_DIR}/quickec2.conf"
USER_DATA_FILE="${QUICKEC2_DIR}/user-data.sh"

# Dry-run flag (set by main script)
DRY_RUN="${DRY_RUN:-false}"

# ─── aws_cmd ─────────────────────────────────────────────────────────────────
# All AWS CLI calls go through this wrapper.
# In dry-run mode, prints the command and returns a placeholder ID.
# Usage: result=$(aws_cmd ec2 create-vpc --cidr-block 10.0.0.0/16 ...)
aws_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "aws $*" >&2
    # Return a placeholder so chained commands don't break
    local service="$1"
    local action="${2:-}"
    case "$action" in
      create-vpc)              echo "vpc-dry12345" ;;
      create-subnet)           echo "subnet-dry12345" ;;
      create-internet-gateway) echo "igw-dry12345" ;;
      allocate-address)        echo "eipalloc-dry12345" ;;
      create-nat-gateway)      echo "nat-dry12345" ;;
      create-route-table)      echo "rtb-dry12345" ;;
      associate-route-table)   echo "rtbassoc-dry12345" ;;
      create-security-group)   echo "sg-dry12345" ;;
      describe-images)         echo "ami-dry12345" ;;
      create-key-pair)         echo "key-dry12345" ;;
      run-instances)           echo "i-dry12345" ;;
      describe-instances)      echo "1.2.3.4" ;;
      create-role)             echo "arn:aws:iam::123456789012:role/dry-role" ;;
      create-instance-profile) echo "arn:aws:iam::123456789012:instance-profile/dry-profile" ;;
      get-caller-identity)     echo "123456789012" ;;
      create-bucket)           echo "" ;;
      describe-instance-information) echo "Online" ;;
      *)                       echo "dry-placeholder" ;;
    esac
    return 0
  fi

  aws "$@"
}

# ─── save_resource ────────────────────────────────────────────────────────────
# Append KEY=VALUE to resources.env
save_resource() {
  local key="$1"
  local value="$2"
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  echo "${key}=${value}" >> "$RESOURCES_FILE"
}

# ─── tag_resource ─────────────────────────────────────────────────────────────
# Tag a resource with Name, CreatedBy, CreatedAt
tag_resource() {
  local resource_id="$1"
  local name="$2"
  local region="$3"
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  aws_cmd ec2 create-tags \
    --resources "$resource_id" \
    --tags \
      "Key=Name,Value=${name}" \
      "Key=CreatedBy,Value=quickec2" \
      "Key=CreatedAt,Value=${timestamp}" \
    --region "$region" > /dev/null 2>&1 || true
}

# ─── check_prerequisites ─────────────────────────────────────────────────────
check_prerequisites() {
  log_step "Checking prerequisites"

  # AWS CLI
  if ! command -v aws &> /dev/null; then
    die "AWS CLI is not installed. Install from: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  fi
  log_info "AWS CLI: $(aws --version 2>&1 | head -1)"

  # AWS credentials
  if ! aws sts get-caller-identity &> /dev/null; then
    if [[ "$DRY_RUN" == "true" ]]; then
      log_warn "AWS credentials not configured. Continuing in dry-run mode."
      export AWS_ACCOUNT_ID="000000000000"
    else
      die "AWS credentials not configured or invalid. Run: aws configure"
    fi
  else
    local account_id
    account_id=$(aws sts get-caller-identity --query 'Account' --output text)
    log_info "AWS Account: ${account_id}"
    export AWS_ACCOUNT_ID="$account_id"
  fi

  # Session Manager plugin (warning only)
  if ! command -v session-manager-plugin &> /dev/null; then
    log_warn "AWS Session Manager plugin not installed. SSM connections won't work."
    log_warn "Install from: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
  else
    log_info "Session Manager plugin: installed"
  fi
}

# ─── load_resources ───────────────────────────────────────────────────────────
# Source resources.env if it exists
load_resources() {
  if [[ -f "$RESOURCES_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$RESOURCES_FILE"
    return 0
  fi
  return 1
}

# ─── load_config ──────────────────────────────────────────────────────────────
# Source a config file (quickec2.conf)
load_config() {
  local file="${1:-$CONFIG_FILE}"
  if [[ -f "$file" ]]; then
    # shellcheck disable=SC1090
    source "$file"
    # Export profile if set in config and not already overridden by --profile
    if [[ -n "${AWS_PROFILE:-}" ]]; then
      export AWS_PROFILE
    fi
    return 0
  fi
  die "Config file not found: $file"
}

# ─── save_config ──────────────────────────────────────────────────────────────
# Save current config variables to quickec2.conf
save_config() {
  local file="${1:-$CONFIG_FILE}"
  cat > "$file" << EOF
# quickec2 configuration — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
AWS_PROFILE="${AWS_PROFILE:-default}"
PROJECT_NAME="${PROJECT_NAME}"
AWS_REGION="${AWS_REGION}"
NETWORK_MODE="${NETWORK_MODE}"
IP_TYPE="${IP_TYPE:-auto}"
INBOUND_PORTS="${INBOUND_PORTS:-}"
INSTANCE_TYPE="${INSTANCE_TYPE}"
OS_TYPE="${OS_TYPE}"
VOLUME_SIZE="${VOLUME_SIZE}"
VOLUME_TYPE="${VOLUME_TYPE}"
KEY_PAIR_OPTION="${KEY_PAIR_OPTION:-none}"
EXISTING_KEY_NAME="${EXISTING_KEY_NAME:-}"
SOFTWARE="${SOFTWARE}"
NODE_VERSION="${NODE_VERSION:-}"
PYTHON_VERSION="${PYTHON_VERSION:-}"
CREATE_S3="${CREATE_S3}"
S3_BUCKET_NAME="${S3_BUCKET_NAME:-}"
EOF
  log_success "Config saved to ${file}"
}

# ─── print_summary ────────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${BOLD}=== Configuration Summary ===${NC}"
  echo -e "  Project:       ${CYAN}${PROJECT_NAME}${NC}"
  echo -e "  Region:        ${CYAN}${AWS_REGION}${NC}"
  echo -e "  Network:       ${CYAN}${NETWORK_MODE}${NC}"
  if [[ "$NETWORK_MODE" == "public" ]]; then
    echo -e "  IP type:       ${CYAN}${IP_TYPE}${NC}"
    echo -e "  Inbound ports: ${CYAN}${INBOUND_PORTS}${NC}"
    echo -e "  Key pair:      ${CYAN}${KEY_PAIR_OPTION}${NC}"
  fi
  echo -e "  Instance type: ${CYAN}${INSTANCE_TYPE}${NC}"
  echo -e "  OS:            ${CYAN}${OS_TYPE}${NC}"
  echo -e "  Volume:        ${CYAN}${VOLUME_SIZE} GB ${VOLUME_TYPE}${NC}"
  echo -e "  Software:      ${CYAN}${SOFTWARE}${NC}"
  if [[ "$SOFTWARE" == *"nodejs"* ]]; then
    echo -e "  Node.js:       ${CYAN}v${NODE_VERSION}${NC}"
  fi
  if [[ "$SOFTWARE" == *"python"* ]]; then
    echo -e "  Python:        ${CYAN}${PYTHON_VERSION}${NC}"
  fi
  echo -e "  S3 bucket:     ${CYAN}${CREATE_S3}${NC}"
  if [[ "$CREATE_S3" == "yes" ]]; then
    echo -e "  Bucket name:   ${CYAN}${S3_BUCKET_NAME}${NC}"
  fi
  echo ""
}

# ─── OS helpers ───────────────────────────────────────────────────────────────
get_ami_owner() {
  case "$OS_TYPE" in
    al2023)     echo "amazon" ;;
    ubuntu*)    echo "099720109477" ;;  # Canonical
  esac
}

get_ami_pattern() {
  case "$OS_TYPE" in
    al2023)      echo "al2023-ami-2023.*-x86_64" ;;
    ubuntu2204)  echo "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" ;;
    ubuntu2404)  echo "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" ;;
  esac
}

get_root_device() {
  case "$OS_TYPE" in
    al2023)     echo "/dev/xvda" ;;
    ubuntu*)    echo "/dev/sda1" ;;
  esac
}

get_default_user() {
  case "$OS_TYPE" in
    al2023)     echo "ec2-user" ;;
    ubuntu*)    echo "ubuntu" ;;
  esac
}
