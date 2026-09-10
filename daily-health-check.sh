#!/usr/bin/env bash
set -uo pipefail

DISK_WARN="${DISK_WARN:-80}"
INODE_WARN="${INODE_WARN:-80}"
LOG_DIR="${LOG_DIR:-/var/log/vps-health}"
EXIT_CODE=0

if [[ "$EUID" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi
mkdir -p "$LOG_DIR"

LOG_FILE="${LOG_DIR}/health-$(date +%F).log"
exec > >(tee -a "$LOG_FILE") 2>&1

section() { printf '\n===== %s =====\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; EXIT_CODE=1; }

printf '\n######## VPS HEALTH CHECK %s ########\n' "$(date --iso-8601=seconds)"

section "Host"
hostnamectl 2>/dev/null || hostname
uptime
printf 'CPU cores: %s\n' "$(nproc)"
printf 'Load: %s\n' "$(cut -d' ' -f1-3 /proc/loadavg)"
timedatectl show -p Timezone -p NTPSynchronized 2>/dev/null || true

section "Memory"
free -h
swapon --show || true

section "Filesystems"
df -hT -x tmpfs -x devtmpfs
while read -r pct mount; do
  pct="${pct%\%}"
  if [[ "$pct" =~ ^[0-9]+$ ]] && (( pct >= DISK_WARN )); then
    warn "Disk usage on $mount is ${pct}% (threshold ${DISK_WARN}%)."
  fi
done < <(df -P -x tmpfs -x devtmpfs | awk 'NR>1 {print $5, $6}')

section "Inodes"
df -ih -x tmpfs -x devtmpfs
while read -r pct mount; do
  pct="${pct%\%}"
  if [[ "$pct" =~ ^[0-9]+$ ]] && (( pct >= INODE_WARN )); then
    warn "Inode usage on $mount is ${pct}% (threshold ${INODE_WARN}%)."
  fi
done < <(df -Pi -x tmpfs -x devtmpfs | awk 'NR>1 {print $5, $6}')

section "Failed systemd units"
FAILED_UNITS="$(systemctl --failed --no-legend 2>/dev/null || true)"
if [[ -n "$FAILED_UNITS" ]]; then
  printf '%s\n' "$FAILED_UNITS"
  warn "One or more systemd units are failed."
else
  echo "None"
fi

section "Docker"
if command -v docker >/dev/null 2>&1; then
  if systemctl is-active --quiet docker; then
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'
    UNHEALTHY="$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null || true)"
    if [[ -n "$UNHEALTHY" ]]; then
      printf 'Unhealthy containers:\n%s\n' "$UNHEALTHY"
      warn "Docker has unhealthy containers."
    fi

    EXITED="$(docker ps -a --filter status=exited --format '{{.Names}} {{.Status}}' 2>/dev/null || true)"
    if [[ -n "$EXITED" ]]; then
      printf '\nExited containers (review; some one-shot containers may be expected):\n%s\n' "$EXITED"
    fi

    printf '\nResource snapshot:\n'
    docker stats --no-stream \
      --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.PIDs}}' || true

    printf '\nDocker disk usage:\n'
    docker system df || true
  else
    warn "Docker service is not active."
  fi
else
  warn "Docker command is not installed."
fi

section "Reverse proxy"
if command -v nginx >/dev/null 2>&1; then
  if nginx -t 2>&1; then
    systemctl is-active nginx || warn "Nginx is installed but not active."
  else
    warn "Nginx configuration test failed."
  fi
else
  echo "Nginx not installed."
fi

section "Security services"
if command -v ufw >/dev/null 2>&1; then
  ufw status verbose || true
fi
if command -v fail2ban-client >/dev/null 2>&1; then
  fail2ban-client status sshd || warn "Fail2ban sshd jail is unavailable."
fi

section "APT"
UPGRADABLE="$(
  apt list --upgradable 2>/dev/null |
  tail -n +2 |
  sed '/^[[:space:]]*$/d' |
  wc -l
)"
printf 'Upgradeable packages: %s\n' "$UPGRADABLE"

if [[ -f /var/run/reboot-required ]]; then
  warn "System reboot is required."
  cat /var/run/reboot-required.pkgs 2>/dev/null || true
fi

section "Recent high-priority journal entries"
journalctl -p 0..3 --since '24 hours ago' --no-pager -n 80 2>/dev/null || true

section "Listening TCP/UDP sockets"
ss -lntup 2>/dev/null || true

# Keep only 30 days of local health logs.
find "$LOG_DIR" -type f -name 'health-*.log' -mtime +30 -delete 2>/dev/null || true

printf '\nHealth check completed. Log: %s\n' "$LOG_FILE"
exit "$EXIT_CODE"
