#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Generic Docker-volume/config backup.
#
# IMPORTANT:
# This is a FILE-LEVEL backup. For PostgreSQL/MySQL/SQLite or another stateful
# service, add an application-consistent dump before this script runs.
#
# Examples:
#   bash backup-docker-volumes.sh
#   BACKUP_ROOT=/mnt/remote-backups RETENTION_DAYS=30 bash backup-docker-volumes.sh

BACKUP_ROOT="${BACKUP_ROOT:-/srv/backups/docker-volumes}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
BACKUP_IMAGE="${BACKUP_IMAGE:-alpine:3.22}"

if [[ "$EUID" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "Docker is required." >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="${BACKUP_ROOT}/${STAMP}"
install -d -m 700 "$BACKUP_ROOT" "$DEST"

echo "Backup destination: $DEST"
echo "WARNING: use pg_dump/mysqldump/application-native backup for live databases."

mapfile -t VOLUMES < <(docker volume ls -q | sort)

if (( ${#VOLUMES[@]} == 0 )); then
  echo "No Docker volumes found."
else
  docker image inspect "$BACKUP_IMAGE" >/dev/null 2>&1 || docker pull "$BACKUP_IMAGE"

  for vol in "${VOLUMES[@]}"; do
    safe="$(printf '%s' "$vol" | tr -c 'A-Za-z0-9_.-' '_')"
    echo "Backing up volume: $vol"
    docker run --rm \
      -v "${vol}:/source:ro" \
      -v "${DEST}:/backup" \
      "$BACKUP_IMAGE" \
      sh -c "tar czf '/backup/${safe}.tar.gz' -C /source ."
  done
fi

echo "Backing up host configuration"
tar czf "${DEST}/host-config.tar.gz" \
  --ignore-failed-read \
  /srv/apps \
  /etc/nginx \
  /etc/letsencrypt \
  /etc/docker \
  /etc/fail2ban \
  /etc/ssh/sshd_config \
  /etc/ssh/sshd_config.d \
  2>/dev/null || true

(
  cd "$DEST"
  sha256sum ./*.tar.gz > SHA256SUMS 2>/dev/null || true
)

echo "Backup size:"
du -sh "$DEST"

echo "Deleting backup sets older than ${RETENTION_DAYS} days"
find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
  -mtime "+${RETENTION_DAYS}" -print -exec rm -rf -- {} +

cat <<EOF

Backup complete: $DEST

Do not treat a backup as valid until you have tested a restore.
For important data, keep another copy outside this VPS/provider.
EOF
