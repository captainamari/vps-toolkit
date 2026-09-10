#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Ubuntu 24.04 VPS bootstrap for a Docker-based personal server.
#
# This toolkit assumes you log in to the server as the root account
# consistently (no separate sudo/admin user is created).
#
# Examples:
#   bash 01-bootstrap.sh
#   SSH_PORT=22 SWAP_GB=4 INSTALL_NGINX=1 bash 01-bootstrap.sh
#
# Important:
# - This script does NOT disable password root SSH login by default.
# - Test SSH key login for root in a second terminal before enabling hardening.
# - Keep Docker application ports bound to 127.0.0.1 and expose only 80/443
#   through Nginx unless a service genuinely needs direct public access.

TIMEZONE="${TIMEZONE:-UTC}"
SSH_PORT="${SSH_PORT:-22}"
SWAP_GB="${SWAP_GB:-4}"
INSTALL_NGINX="${INSTALL_NGINX:-1}"
APPLY_OS_UPDATES="${APPLY_OS_UPDATES:-1}"
ENABLE_SSH_HARDENING="${ENABLE_SSH_HARDENING:-0}"

log()  { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

if [[ "${EUID}" -ne 0 ]]; then
  die "Run as root, e.g. bash $0"
fi

[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH_PORT must be numeric."
(( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "SSH_PORT must be 1..65535."
[[ "$SWAP_GB" =~ ^[0-9]+$ ]] || die "SWAP_GB must be numeric."

source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "This script is intended for Ubuntu."
if [[ "${VERSION_ID:-}" != "24.04" ]]; then
  warn "Expected Ubuntu 24.04, detected ${VERSION_ID:-unknown}. Continuing cautiously."
fi

log "Current system"
uname -a
printf 'OS: %s\n' "${PRETTY_NAME:-unknown}"
printf 'Virtualization: %s\n' "$(systemd-detect-virt 2>/dev/null || echo unknown)"
printf 'CPU cores: %s\n' "$(nproc)"
free -h || true
df -hT / || true
ip -br addr || true

export DEBIAN_FRONTEND=noninteractive

log "Updating APT metadata"
apt-get update

if [[ "$APPLY_OS_UPDATES" == "1" ]]; then
  log "Applying currently available OS package upgrades"
  apt-get upgrade -y
else
  warn "APPLY_OS_UPDATES=0: package upgrades were not installed."
fi

log "Installing baseline administration/security packages"
apt-get install -y \
  ca-certificates curl wget gnupg lsb-release jq \
  git vim nano tmux htop btop tree unzip zip rsync \
  ncdu iotop sysstat net-tools dnsutils traceroute \
  ufw fail2ban unattended-upgrades needrestart \
  cron logrotate acl

timedatectl set-timezone "$TIMEZONE"
systemctl enable --now cron >/dev/null
systemctl enable --now sysstat >/dev/null 2>&1 || true
systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true

log "Configuring automatic security updates without automatic reboot"
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat >/etc/apt/apt.conf.d/52unattended-local <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
EOF

systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

if (( SWAP_GB > 0 )); then
  if swapon --show=NAME --noheadings | grep -q .; then
    log "Swap already exists; leaving it unchanged"
    swapon --show
  else
    log "Creating ${SWAP_GB} GiB swapfile"
    if [[ -e /swapfile ]]; then
      warn "/swapfile exists but is not active. It will not be overwritten."
    else
      if ! fallocate -l "${SWAP_GB}G" /swapfile; then
        dd if=/dev/zero of=/swapfile bs=1M count="$((SWAP_GB * 1024))" status=progress
      fi
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      grep -qE '^/swapfile\s' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
  fi

  cat >/etc/sysctl.d/99-vps-memory.conf <<'EOF'
vm.swappiness=10
EOF
  sysctl --system >/dev/null
fi

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
    return
  fi

  log "Installing Docker Engine from Docker's official APT repository"
  apt-get remove -y \
    docker.io docker-compose docker-compose-v2 docker-doc docker-buildx \
    podman-docker containerd runc 2>/dev/null || true

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

install_docker

log "Configuring bounded Docker json-file logs"
mkdir -p /etc/docker
DOCKER_DAEMON_JSON=/etc/docker/daemon.json
DOCKER_CFG_CHANGED=0

if [[ -f "$DOCKER_DAEMON_JSON" ]]; then
  if jq empty "$DOCKER_DAEMON_JSON" >/dev/null 2>&1; then
    tmp="$(mktemp)"
    jq '
      .["log-driver"] = "json-file"
      | .["log-opts"] = ((.["log-opts"] // {}) + {"max-size":"20m","max-file":"5"})
      | .["live-restore"] = true
    ' "$DOCKER_DAEMON_JSON" >"$tmp"
    if ! cmp -s "$tmp" "$DOCKER_DAEMON_JSON"; then
      cp -a "$DOCKER_DAEMON_JSON" "${DOCKER_DAEMON_JSON}.bak.$(date +%Y%m%d%H%M%S)"
      install -m 644 "$tmp" "$DOCKER_DAEMON_JSON"
      DOCKER_CFG_CHANGED=1
    fi
    rm -f "$tmp"
  else
    warn "$DOCKER_DAEMON_JSON is not valid JSON; leaving it untouched."
  fi
else
  cat >"$DOCKER_DAEMON_JSON" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  },
  "live-restore": true
}
EOF
  DOCKER_CFG_CHANGED=1
fi

if [[ "$DOCKER_CFG_CHANGED" == "1" ]]; then
  if [[ "$(docker ps -q 2>/dev/null | wc -l)" -eq 0 ]]; then
    systemctl restart docker
  else
    warn "Docker daemon config changed but running containers were detected."
    warn "Restart Docker later during a maintenance window: systemctl restart docker"
  fi
fi

log "Configuring UFW for host services"
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable

log "Configuring Fail2ban for SSH"
cat >/etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
backend = systemd
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h
bantime.increment = true
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

if [[ "$INSTALL_NGINX" == "1" ]]; then
  log "Installing Nginx and Certbot"
  apt-get install -y nginx certbot python3-certbot-nginx
  systemctl enable --now nginx
  nginx -t
fi

log "Creating application/data/backup layout"
install -d -m 755 /srv/apps /srv/data /srv/logs
install -d -m 700 /srv/backups

if [[ "$ENABLE_SSH_HARDENING" == "1" ]]; then
  if [[ ! -s /root/.ssh/authorized_keys ]]; then
    warn "SSH hardening skipped: no authorized_keys for root. Add your public key to /root/.ssh/authorized_keys first."
  else
    log "Applying SSH key-only hardening for root"
    cat >/etc/ssh/sshd_config.d/99-vps-hardening.conf <<EOF
Port ${SSH_PORT}
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 4
LoginGraceTime 30
X11Forwarding no
EOF
    sshd -t
    systemctl reload ssh
  fi
else
  warn "SSH password login hardening was NOT enabled."
  warn "After testing root key login, rerun with ENABLE_SSH_HARDENING=1 to disable password login."
fi

log "Final validation"
printf '\n--- UFW ---\n'
ufw status verbose || true
printf '\n--- Fail2ban ---\n'
fail2ban-client status sshd || true
printf '\n--- Docker ---\n'
docker version --format 'Server: {{.Server.Version}}' 2>/dev/null || docker --version
docker compose version || true
printf '\n--- Memory / swap ---\n'
free -h
swapon --show || true
printf '\n--- Disk ---\n'
df -hT /
printf '\n--- Listening TCP ports ---\n'
ss -lntp || true

if [[ -f /var/run/reboot-required ]]; then
  warn "A reboot is required after package updates."
fi

cat <<EOF

Bootstrap complete.

Recommended next actions:
1. Test a NEW SSH session before changing/closing the current one.
2. Keep container app ports on loopback, e.g.:
     127.0.0.1:3000:8080
   and let Nginx expose only 80/443.
3. Put each app under /srv/apps/<app-name> and persistent data under /srv/data.
4. Configure DNS, then obtain TLS certs with Certbot.
5. Run daily-health-check.sh and make application-aware backups before production use.
EOF
