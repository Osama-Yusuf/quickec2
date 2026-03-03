#!/usr/bin/env bash
# quickec2 — standalone cleanup entry point
set -euo pipefail
export AWS_PAGER=""

QUICKEC2_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse --profile flag
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      export AWS_PROFILE="${2:-}"
      [[ -z "$AWS_PROFILE" ]] && { echo "ERROR: --profile requires a profile name"; exit 1; }
      shift 2
      ;;
    *) shift ;;
  esac
done

# Source libraries
source "${QUICKEC2_DIR}/lib/common.sh"
source "${QUICKEC2_DIR}/lib/cleanup.sh"

# Check for resources file
if [[ ! -f "$RESOURCES_FILE" ]]; then
  die "No resources.env found. Nothing to clean up."
fi

# Load resource IDs
load_resources

# Save CLI --profile override before sourcing config
PROFILE_OVERRIDE="${AWS_PROFILE:-}"

# Determine region and profile from config
REGION="${AWS_REGION:-eu-west-1}"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  REGION="${AWS_REGION:-$REGION}"
fi

# CLI --profile takes precedence over config value
if [[ -n "$PROFILE_OVERRIDE" ]]; then
  export AWS_PROFILE="$PROFILE_OVERRIDE"
elif [[ -n "${AWS_PROFILE:-}" ]]; then
  export AWS_PROFILE
fi

echo ""
echo -e "${BOLD}This will delete ALL ${PROJECT_NAME:-quickec2} resources:${NC}"
echo ""

# Show what will be deleted
[[ -n "${INSTANCE_ID:-}" ]]         && echo "  - EC2 instance: ${INSTANCE_ID}"
[[ -n "${SG_ID:-}" ]]               && echo "  - Security group: ${SG_ID}"
[[ -n "${ROLE_NAME:-}" ]]           && echo "  - IAM role: ${ROLE_NAME}"
[[ -n "${VPC_ID:-}" ]]              && echo "  - VPC: ${VPC_ID}"
[[ -n "${NAT_GW_ID:-}" ]]           && echo "  - NAT Gateway: ${NAT_GW_ID}"
[[ -n "${S3_BUCKET_NAME:-}" ]]      && echo "  - S3 bucket: ${S3_BUCKET_NAME}"
[[ "${KEY_CREATED:-}" == "true" ]]  && echo "  - Key pair: ${KEY_NAME:-}"

echo ""
read -rp "Are you sure? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
  echo "Aborted."
  exit 0
fi

cleanup_all "$REGION"
