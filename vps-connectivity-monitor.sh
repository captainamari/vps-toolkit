#!/usr/bin/env bash
set -uo pipefail

# Test outbound HTTPS reachability from this VPS. HTTP 2xx, 3xx, and 4xx
# responses count as reachable because DNS, TCP, TLS, and the remote platform
# all responded. After consecutive failures, send one alert per incident
# through the local notification-hub.

readonly ENV_FILE="${ENV_FILE:-/root/notification-hub/.env}"
readonly HUB_URL="${HUB_URL:-http://127.0.0.1:8080/api/v1/notify}"
readonly STATE_DIR="${STATE_DIR:-/var/lib/vps-connectivity-monitor}"
readonly FAILURE_FILE="${STATE_DIR}/failure-count"
readonly ALERTED_FILE="${STATE_DIR}/alerted"
readonly LOG_TAG="vps-connectivity-monitor"
readonly MAX_TIME="${MAX_TIME:-15}"
readonly FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-2}"

declare -ar TARGETS=(
  "YouTube|https://www.youtube.com/generate_204"
  "X/Twitter|https://x.com/robots.txt"
  "Bilibili|https://api.bilibili.com/x/web-interface/nav"
  "Weibo|https://weibo.com/robots.txt"
  "Instagram|https://www.instagram.com/robots.txt"
)

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

failed=()

check_target() {
  local name="$1"
  local url="$2"
  local code

  code="$(
    curl       --ipv4       --silent       --show-error       --location       --output /dev/null       --connect-timeout 8       --max-time "$MAX_TIME"       --retry 1       --user-agent "Mozilla/5.0 VPS-Connectivity-Monitor/1.0"       --write-out '%{http_code}'       "$url" 2>/dev/null
  )" || {
    failed+=("$name")
    return
  }

  if [[ ! "$code" =~ ^[234][0-9][0-9]$ ]]; then
    failed+=("${name}(HTTP ${code:-000})")
  fi
}

for target in "${TARGETS[@]}"; do
  IFS='|' read -r name url <<< "$target"
  check_target "$name" "$url"
done

if (("${#failed[@]}" == 0)); then
  printf '0\n' > "$FAILURE_FILE"
  rm -f "$ALERTED_FILE"
  logger -t "$LOG_TAG" "All configured platforms are reachable"
  exit 0
fi

previous_failures=0
if [[ -r "$FAILURE_FILE" ]]; then
  read -r previous_failures < "$FAILURE_FILE" || previous_failures=0
fi
[[ "$previous_failures" =~ ^[0-9]+$ ]] || previous_failures=0

current_failures=$((previous_failures + 1))
printf '%s\n' "$current_failures" > "$FAILURE_FILE"

failure_list="$(IFS=', '; echo "${failed[*]}")"
logger -t "$LOG_TAG"   "Connectivity failure ${current_failures}/${FAILURE_THRESHOLD}: ${failure_list}"

# Suppress a single transient failure and repeated alerts for the same incident.
# A successful run removes ALERTED_FILE and rearms notifications.
if ((current_failures < FAILURE_THRESHOLD)) || [[ -e "$ALERTED_FILE" ]]; then
  exit 1
fi

if [[ ! -r "$ENV_FILE" ]]; then
  logger -t "$LOG_TAG" "Cannot read ${ENV_FILE}; alert not sent"
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

if [[ -z "${API_TOKEN:-}" ]]; then
  logger -t "$LOG_TAG" "API_TOKEN is unavailable; alert not sent"
  exit 1
fi

payload="$(
  printf     '{"channel":"default","level":"error","title":"VPS outbound connectivity failure","message":"Unreachable platforms: %s. Consecutive failed checks: %s.","source":"vps-connectivity-monitor"}'     "$failure_list"     "$current_failures"
)"

if curl   --silent   --show-error   --fail-with-body   --max-time 15   --request POST   "$HUB_URL"   --header "Authorization: Bearer ${API_TOKEN}"   --header "Content-Type: application/json"   --data "$payload" >/dev/null
then
  : > "$ALERTED_FILE"
  chmod 600 "$ALERTED_FILE"
  logger -t "$LOG_TAG" "Telegram alert submitted: ${failure_list}"
else
  logger -t "$LOG_TAG" "notification-hub rejected or failed to deliver the alert"
fi

exit 1
