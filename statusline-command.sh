#!/bin/bash
input=$(cat)
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')
cwd="${cwd/#$HOME/\~}"
model=$(echo "$input" | jq -r '.model.display_name // ""')
ctx_remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')

# Git branch
git_info=""
if git_branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null); then
  git_info=" ($git_branch)"
fi

# ANSI color codes
RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
BLUE=$'\033[1;34m'
MAGENTA=$'\033[0;35m'
GRAY=$'\033[0;37m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

# Color based on utilization %
usage_color() {
  local pct=$1
  if [ "$pct" -ge 95 ]; then
    printf '%s' "$RED"
  elif [ "$pct" -ge 80 ]; then
    printf '%s' "$YELLOW"
  else
    printf '%s' "$GREEN"
  fi
}

# Fetch usage from Anthropic API with cache (360s)
CACHE_FILE="/tmp/claude-usage-cache.json"
CACHE_TTL=360
now=$(date +%s)

use_cache=false
if [ -f "$CACHE_FILE" ]; then
  cache_time=$(python3 -c "import json; d=json.load(open('$CACHE_FILE')); print(d.get('_ts', 0))" 2>/dev/null || echo 0)
  if [ $(( now - cache_time )) -lt $CACHE_TTL ]; then
    use_cache=true
  fi
fi

five_pct=""
seven_pct=""
five_resets_at=""
seven_resets_at=""

if [ "$use_cache" = true ]; then
  five_pct=$(python3 -c "import json; d=json.load(open('$CACHE_FILE')); print(int(d.get('five_hour_pct', -1)))" 2>/dev/null)
  seven_pct=$(python3 -c "import json; d=json.load(open('$CACHE_FILE')); print(int(d.get('seven_day_pct', -1)))" 2>/dev/null)
  five_resets_at=$(python3 -c "import json; d=json.load(open('$CACHE_FILE')); print(d.get('five_resets_at', ''))" 2>/dev/null)
  seven_resets_at=$(python3 -c "import json; d=json.load(open('$CACHE_FILE')); print(d.get('seven_resets_at', ''))" 2>/dev/null)
else
  # Get OAuth token from macOS Keychain
  TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['claudeAiOauth']['accessToken'])" 2>/dev/null)

  if [ -n "$TOKEN" ]; then
    api_resp=$(curl -s --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
      -H "Authorization: Bearer $TOKEN" \
      -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null)

    parsed=$(API_RESP="$api_resp" python3 - <<'PYEOF' 2>/dev/null
import json, sys, os

resp = os.environ.get('API_RESP', '')
try:
    d = json.loads(resp)
except Exception:
    sys.exit(1)

if 'error' in d:
    sys.exit(1)

five = d.get('five_hour', {})
seven = d.get('seven_day', {})

def to_pct(val):
    if val is None:
        return -1
    return min(100, int(float(val)))

five_pct = to_pct(five.get('utilization'))
seven_pct = to_pct(seven.get('utilization'))
five_resets_at = five.get('resets_at', '')
seven_resets_at = seven.get('resets_at', '')

print(f"{five_pct}|{seven_pct}|{five_resets_at}|{seven_resets_at}")
PYEOF
    )

    if [ -n "$parsed" ]; then
      IFS='|' read -r five_pct seven_pct five_resets_at seven_resets_at <<< "$parsed"
      python3 - <<PYEOF 2>/dev/null
import json, time
d = {
  '_ts': int(time.time()),
  'five_hour_pct': $five_pct,
  'seven_day_pct': $seven_pct,
  'five_resets_at': '$five_resets_at',
  'seven_resets_at': '$seven_resets_at'
}
json.dump(d, open('$CACHE_FILE', 'w'))
PYEOF
    fi
  fi
fi

# Calculate remaining time from resets_at ISO string
# Output: "3h21m" if < 24h, "2d" if >= 24h, "" if unavailable
fmt_remaining() {
  local iso_str="$1"
  [ -z "$iso_str" ] && return
  python3 - <<PYEOF 2>/dev/null
import sys
from datetime import datetime, timezone, timedelta

iso = '$iso_str'
try:
    dt = datetime.fromisoformat(iso.replace('Z', '+00:00'))
    now = datetime.now(timezone.utc)
    diff = dt - now
    secs = int(diff.total_seconds())
    if secs <= 0:
        print('')
    elif secs < 86400:
        h = secs // 3600
        m = (secs % 3600) // 60
        print(f'{h}h{m:02d}m')
    else:
        d = secs // 86400
        print(f'{d}d')
except Exception:
    print('')
PYEOF
}

line1="${BLUE}#${RESET} ${BOLD}${YELLOW}${cwd}${RESET}${CYAN}${git_info}${RESET} ${GRAY}[$(date +%H:%M:%S)]${RESET} ${MAGENTA}${model}${RESET}"

if [ -n "$ctx_remaining" ]; then
  ctx_used=$(( 100 - ctx_remaining ))
  ctx_col=$(usage_color "$ctx_used")
  line1="${line1} ${ctx_col}ctx ${ctx_used}%${RESET}"
fi

if [ -n "$five_pct" ] && [ "$five_pct" -ge 0 ] 2>/dev/null; then
  col=$(usage_color "$five_pct")
  five_remaining=$(fmt_remaining "$five_resets_at")
  remaining_str=""
  [ -n "$five_remaining" ] && remaining_str=" ${GRAY}(${five_remaining})${RESET}"
  five_part="${GRAY}[5h]${RESET} ${col}${five_pct}%${RESET}${remaining_str}"
else
  five_part="${GRAY}[5h] --%${RESET}"
fi

if [ -n "$seven_pct" ] && [ "$seven_pct" -ge 0 ] 2>/dev/null; then
  col=$(usage_color "$seven_pct")
  seven_remaining=$(fmt_remaining "$seven_resets_at")
  remaining_str=""
  [ -n "$seven_remaining" ] && remaining_str=" ${GRAY}(${seven_remaining})${RESET}"
  seven_part="${GRAY}[7d]${RESET} ${col}${seven_pct}%${RESET}${remaining_str}"
else
  seven_part="${GRAY}[7d] --%${RESET}"
fi

printf '%s  %s  %s' "$line1" "$five_part" "$seven_part"
