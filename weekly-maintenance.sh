#!/usr/bin/env bash
set -Eeuo pipefail

# Safe-by-default weekly host maintenance.
#
# Default: refresh metadata, clean harmless caches/logs, report updates.
# To actually install normal OS upgrades:
#   APPLY_UPDATES=1 bash weekly-maintenance.sh
#
# This script deliberately does NOT:
# - docker compose pull/up automatically
# - delete Docker volumes
# - aggressively delete unused images
# - automatically reboot the server

APPLY_UPDATES="${APPLY_UPDATES:-0}"
VACUUM_DAYS="${VACUUM_DAYS:-14}"
BUILDER_PRUNE_HOURS="${BUILDER_PRUNE_HOURS:-168}"

if [[ "$EUID" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

log() { printf '\n===== %s =====\n' "$*"; }

log "APT metadata"
apt-get update

log "Available upgrades"
apt list --upgradable 2>/dev/null || true

if [[ "$APPLY_UPDATES" == "1" ]]; then
  log "Installing OS upgrades"
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
else
  echo "APPLY_UPDATES=0: upgrades were not installed."
fi

log "APT cache cleanup"
apt-get autoclean -y

log "Journal retention"
journalctl --vacuum-time="${VACUUM_DAYS}d" || true

log "Docker cleanup (non-destructive)"
if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
  docker image prune -f
  docker builder prune -f --filter "until=${BUILDER_PRUNE_HOURS}h"
  docker system df
  printf '\nRunning container image references:\n'
  docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
else
  echo "Docker inactive or unavailable."
fi

log "Services"
systemctl --failed --no-legend || true

log "Disk / inode status"
df -hT -x tmpfs -x devtmpfs
df -ih -x tmpfs -x devtmpfs

log "Security"
ufw status verbose 2>/dev/null || true
fail2ban-client status sshd 2>/dev/null || true

log "Reboot requirement"
if [[ -f /var/run/reboot-required ]]; then
  echo "REBOOT REQUIRED"
  cat /var/run/reboot-required.pkgs 2>/dev/null || true
else
  echo "No reboot currently required."
fi

cat <<'EOF'

Weekly maintenance complete.

Before upgrading application containers:
1. Read the application's release notes.
2. Take an application-consistent backup (database dump where applicable).
3. Record current image tags/digests.
4. Pull and recreate one application at a time.
5. Run its health/functional checks.
6. Keep the previous image available for rollback.
EOF
