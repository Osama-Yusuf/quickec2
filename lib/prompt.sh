#!/usr/bin/env bash
# quickec2 — interactive prompt helpers

# ─── prompt_input ─────────────────────────────────────────────────────────────
# Usage: result=$(prompt_input "Project name" "my-default")
prompt_input() {
  local label="$1"
  local default="${2:-}"
  local value

  if [[ -n "$default" ]]; then
    read -rp "$(echo -e "${BOLD}${label}${NC} [${DIM}${default}${NC}]: ")" value
    value="${value:-$default}"
  else
    read -rp "$(echo -e "${BOLD}${label}${NC}: ")" value
    while [[ -z "$value" ]]; do
      echo -e "${RED}  This field is required.${NC}"
      read -rp "$(echo -e "${BOLD}${label}${NC}: ")" value
    done
  fi
  echo "$value"
}

# ─── prompt_select ────────────────────────────────────────────────────────────
# Usage: result=$(prompt_select "Instance type" "t3.micro" "t3.nano" "t3.micro" "t3.small")
# First arg after label is the default; rest are options
prompt_select() {
  local label="$1"
  local default="$2"
  shift 2
  local options=("$@")

  echo -e "${BOLD}${label}${NC}" >&2
  local i=1
  for opt in "${options[@]}"; do
    if [[ "$opt" == "$default" ]]; then
      echo -e "  ${GREEN}${i})${NC} ${opt} ${DIM}(default)${NC}" >&2
    else
      echo -e "  ${i}) ${opt}" >&2
    fi
    ((i++))
  done

  local choice
  read -rp "$(echo -e "  Choose [${DIM}${default}${NC}]: ")" choice

  if [[ -z "$choice" ]]; then
    echo "$default"
    return
  fi

  # If numeric, use as index
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
    echo "${options[$((choice - 1))]}"
    return
  fi

  # If exact match of an option, accept it
  for opt in "${options[@]}"; do
    if [[ "$choice" == "$opt" ]]; then
      echo "$choice"
      return
    fi
  done

  # Invalid — use default
  echo -e "  ${YELLOW}Invalid choice, using default: ${default}${NC}" >&2
  echo "$default"
}

# ─── prompt_multiselect ──────────────────────────────────────────────────────
# Usage: result=$(prompt_multiselect "Software" "docker,git" "docker" "git" "nodejs" "python" "nginx" "certbot")
# First arg after label is comma-separated defaults; rest are options
prompt_multiselect() {
  local label="$1"
  local defaults="$2"
  shift 2
  local options=("$@")

  echo -e "${BOLD}${label}${NC} ${DIM}(comma-separated numbers or names)${NC}" >&2
  local i=1
  for opt in "${options[@]}"; do
    local marker=" "
    if [[ ",$defaults," == *",$opt,"* ]]; then
      marker="${GREEN}*${NC}"
    fi
    echo -e "  ${marker} ${i}) ${opt}" >&2
    ((i++))
  done

  local choice
  read -rp "$(echo -e "  Select [${DIM}${defaults}${NC}]: ")" choice

  if [[ -z "$choice" ]]; then
    echo "$defaults"
    return
  fi

  # Parse comma-separated input (numbers or names)
  local result=()
  IFS=',' read -ra parts <<< "$choice"
  for part in "${parts[@]}"; do
    part="$(echo "$part" | xargs)" # trim whitespace
    if [[ "$part" =~ ^[0-9]+$ ]] && (( part >= 1 && part <= ${#options[@]} )); then
      result+=("${options[$((part - 1))]}")
    else
      # Check if it's a valid option name
      for opt in "${options[@]}"; do
        if [[ "$part" == "$opt" ]]; then
          result+=("$opt")
          break
        fi
      done
    fi
  done

  if [[ ${#result[@]} -eq 0 ]]; then
    echo "$defaults"
  else
    local IFS=','
    echo "${result[*]}"
  fi
}

# ─── prompt_confirm ──────────────────────────────────────────────────────────
# Usage: prompt_confirm "Create S3 bucket?" "no" && echo "yes"
# Returns 0 for yes, 1 for no. Also echoes "yes" or "no".
prompt_confirm() {
  local label="$1"
  local default="${2:-no}"
  local hint

  if [[ "$default" == "yes" ]]; then
    hint="Y/n"
  else
    hint="y/N"
  fi

  local answer
  read -rp "$(echo -e "${BOLD}${label}${NC} [${DIM}${hint}${NC}]: ")" answer
  answer="${answer:-$default}"

  case "${answer,,}" in
    y|yes) echo "yes"; return 0 ;;
    *)     echo "no";  return 1 ;;
  esac
}

# ─── prompt_ports ─────────────────────────────────────────────────────────────
# Usage: result=$(prompt_ports "Inbound ports" "22,80,443")
prompt_ports() {
  local label="$1"
  local default="$2"
  local value

  read -rp "$(echo -e "${BOLD}${label}${NC} ${DIM}(comma-separated)${NC} [${DIM}${default}${NC}]: ")" value
  value="${value:-$default}"

  # Validate: only digits and commas
  if [[ ! "$value" =~ ^[0-9,]+$ ]]; then
    echo -e "${YELLOW}  Invalid ports, using default: ${default}${NC}" >&2
    echo "$default"
    return
  fi

  echo "$value"
}
