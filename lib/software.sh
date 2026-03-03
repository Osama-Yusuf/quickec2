#!/usr/bin/env bash
# quickec2 — dynamic user-data.sh generator

# ─── generate_user_data ───────────────────────────────────────────────────────
# Builds a user-data.sh script based on OS type and selected software
generate_user_data() {
  local os_type="$1"
  local software="$2"        # comma-separated: docker,git,nodejs,python,nginx,certbot
  local node_version="$3"    # 18, 20, 22
  local python_version="$4"  # 3.11, 3.12
  local output_file="$5"

  local default_user
  default_user=$(get_default_user)

  cat > "$output_file" << 'HEADER'
#!/bin/bash
set -euo pipefail

exec > /var/log/user-data.log 2>&1
echo "=== quickec2 user-data started at $(date) ==="

HEADER

  # System update
  if [[ "$os_type" == "al2023" ]]; then
    cat >> "$output_file" << 'EOF'
# Update system packages
dnf update -y

EOF
  else
    cat >> "$output_file" << 'EOF'
# Update system packages
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

EOF
  fi

  # Parse software list and generate install blocks
  IFS=',' read -ra sw_list <<< "$software"
  for sw in "${sw_list[@]}"; do
    sw="$(echo "$sw" | xargs)"
    case "$sw" in
      docker)  _install_docker  "$os_type" "$default_user" >> "$output_file" ;;
      git)     _install_git     "$os_type" >> "$output_file" ;;
      nodejs)  _install_nodejs  "$os_type" "$node_version" >> "$output_file" ;;
      python)  _install_python  "$os_type" "$python_version" >> "$output_file" ;;
      nginx)   _install_nginx   "$os_type" >> "$output_file" ;;
      certbot) _install_certbot "$os_type" >> "$output_file" ;;
    esac
  done

  # Footer
  cat >> "$output_file" << 'FOOTER'
echo "=== quickec2 user-data completed at $(date) ==="
FOOTER

  chmod +x "$output_file"
  log_success "Generated user-data.sh (${os_type}, software: ${software})"
}

# ─── Installer functions ─────────────────────────────────────────────────────

_install_docker() {
  local os_type="$1"
  local default_user="$2"

  if [[ "$os_type" == "al2023" ]]; then
    cat << EOF
# Install Docker (Amazon Linux 2023)
dnf install -y docker
systemctl enable docker
systemctl start docker
usermod -aG docker ${default_user}

# Install docker-compose (v2 plugin)
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-\$(uname -m)" \\
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
docker --version
docker compose version

EOF
  else
    cat << EOF
# Install Docker (Ubuntu — official repo)
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \\
  \$(. /etc/os-release && echo "\$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl start docker
usermod -aG docker ${default_user}
docker --version
docker compose version

EOF
  fi
}

_install_git() {
  local os_type="$1"

  if [[ "$os_type" == "al2023" ]]; then
    cat << 'EOF'
# Install Git
dnf install -y git
git --version

EOF
  else
    cat << 'EOF'
# Install Git
apt-get install -y git
git --version

EOF
  fi
}

_install_nodejs() {
  local os_type="$1"
  local version="$2"

  if [[ "$os_type" == "al2023" ]]; then
    cat << EOF
# Install Node.js ${version} (Amazon Linux 2023)
dnf install -y nodejs${version//./}
node --version
npm --version

EOF
  else
    cat << EOF
# Install Node.js ${version} (Ubuntu — NodeSource)
curl -fsSL https://deb.nodesource.com/setup_${version}.x | bash -
apt-get install -y nodejs
node --version
npm --version

EOF
  fi
}

_install_python() {
  local os_type="$1"
  local version="$2"

  if [[ "$os_type" == "al2023" ]]; then
    cat << EOF
# Install Python ${version} (Amazon Linux 2023)
dnf install -y python${version} python${version}-pip
python${version} --version

EOF
  else
    cat << EOF
# Install Python ${version} (Ubuntu)
apt-get install -y python${version} python${version}-venv python3-pip
python${version} --version

EOF
  fi
}

_install_nginx() {
  local os_type="$1"

  if [[ "$os_type" == "al2023" ]]; then
    cat << 'EOF'
# Install Nginx
dnf install -y nginx
systemctl enable nginx
systemctl start nginx
nginx -v

EOF
  else
    cat << 'EOF'
# Install Nginx
apt-get install -y nginx
systemctl enable nginx
systemctl start nginx
nginx -v

EOF
  fi
}

_install_certbot() {
  local os_type="$1"

  if [[ "$os_type" == "al2023" ]]; then
    cat << 'EOF'
# Install Certbot
dnf install -y certbot python3-certbot-nginx
certbot --version

EOF
  else
    cat << 'EOF'
# Install Certbot
apt-get install -y certbot python3-certbot-nginx
certbot --version

EOF
  fi
}
