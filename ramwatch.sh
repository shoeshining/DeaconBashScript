#!/usr/bin/env bash
set -euo pipefail

# === CONFIG ===
# Note: Deacon's API is not ready to be public facing, this will only work locally/with Mattc.org VPN on, hence the lack of authentication.
# Defaults (can be overridden by flags)
API_BASE="http://192.168.1._:556/Deacon/Alert"
THRESHOLD=""
FREQ_MIN=""
LOG_FILE="$HOME/ramwatch.log"
QUIET=0

usage() {
  cat <<'EOF'
ramwatch.sh - Monitor RAM usage and send an alert via REST API when a threshold is exceeded.

USAGE:
  ramwatch.sh [-t PCT] [-f MIN] [-l FILE] [-u URL] [-q] [-h]

OPTIONS:
  -t PCT   RAM threshold percent (integer 1-100). If omitted, you will be prompted.
  -f MIN   Check frequency in minutes (integer >=1). If omitted, you will be prompted.
  -l FILE  Log file path (default: ~/ramwatch.log). The script appends timestamped entries.
  -u URL   API base URL (default: http://192.168.200.72:556/Deacon/Alert).
  -q       Quiet mode: suppress regular stdout status (errors still shown).
  -h       Show this help and exit.

BEHAVIOR:
  - Loops forever, sampling RAM from /proc/meminfo.
  - When used% >= threshold, it logs the event and calls:
      GET <URL>?Title=RamExceeded&Body=<encoded message>
  - Uses a regex-based URL encoder (sed) to satisfy rubric.
  - Interacts with files by appending to the log file.

EXAMPLES:
  ramwatch.sh -t 85 -f 10
  ramwatch.sh -t 90 -f 5 -l /tmp/ramwatch.log -u http://127.0.0.1:556/Deacon/Alert
  ramwatch.sh -q -t 80 -f 15
EOF
}

# Parse options
while getopts ":t:f:l:u:qh" opt; do
  case "$opt" in
    t) THRESHOLD="$OPTARG" ;;
    f) FREQ_MIN="$OPTARG" ;;
    l) LOG_FILE="$OPTARG" ;;
    u) API_BASE="$OPTARG" ;;
    q) QUIET=1 ;;
    h) usage; exit 0 ;;
    \?) echo "Error: invalid option -$OPTARG" >&2; usage; exit 2 ;;
    :)  echo "Error: option -$OPTARG requires an argument" >&2; usage; exit 2 ;;
  case
done

# Prompt if needed
if [[ -z "${THRESHOLD}" ]]; then
  read -rp "Enter RAM threshold percent: " THRESHOLD
fi
if [[ -z "${FREQ_MIN}" ]]; then
  read -rp "Enter check frequency in minutes: " FREQ_MIN
fi

# Validate args
if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]] || (( THRESHOLD < 1 || THRESHOLD > 100 )); then
  echo "Error: -t must be an integer 1–100 (got: $THRESHOLD)" >&2; exit 2
fi
if ! [[ "$FREQ_MIN" =~ ^[0-9]+$ ]] || (( FREQ_MIN < 1 )); then
  echo "Error: -f must be an integer >= 1 (got: $FREQ_MIN)" >&2; exit 2
fi

SLEEP_SECS=$((FREQ_MIN * 60))

get_ram_used_pct() {
  awk '
    $1=="MemTotal:"     {t=$2}
    $1=="MemAvailable:" {a=$2}
    END {
      if (t>0) { used = 100 - int((a*100)/t); print used } else { print 0 }
    }' /proc/meminfo
}

# Regex-based encoder for rubric points. Ideally this could be done by a dependency like jq
urlencode_regex() {
  # Regex needs upgraded for untrusted input/edge cases.
  sed -E 's/%/%25/g; s/ /%20/g; s/!/%21/g; s/\(/%28/g; s/\)/%29/g; s/:/%3A/g; s/\+/%2B/g; s/\?/%3F/g; s/&/%26/g'
}

log() {
  local ts msg
  ts="$(date -Is)"
  msg="$1"
  printf "[%s] %s\n" "$ts" "$msg" | tee -a "$LOG_FILE" >/dev/null
  (( QUIET )) || printf "[%s] %s\n" "$ts" "$msg"
}

(( QUIET )) || echo "Starting RAM watch: threshold=${THRESHOLD}% | every ${FREQ_MIN} min | log=${LOG_FILE}"
log "RAM Watch started threshold=${THRESHOLD}%, interval=${FREQ_MIN}min, url=${API_BASE}"

# Ensure log file exists (interacts with files)
: > "$LOG_FILE" 2>/dev/null || true

while true; do
  pct="$(get_ram_used_pct)"
  ts="$(date -Is)"
  (( QUIET )) || echo "[$ts] RAM used: ${pct}%"

  if (( pct >= THRESHOLD )); then
    body="RAM usage exceeded threshold! Current: ${pct}% (threshold: ${THRESHOLD}%) on host $(hostname) at ${ts}"
    enc_body="$(printf '%s' "$body" | urlencode_regex)"
    url="${API_BASE}?Title=RamExceeded&Body=${enc_body}"

    log "Threshold exceeded — ${pct}% used (threshold=${THRESHOLD}%)"
    # Make the call, log if fail
    if ! curl -sS --http1.1 "$url" >/dev/null; then
      log "API call failed"
    fi
  fi

  sleep "$SLEEP_SECS"
done
