#!/bin/bash

# ── Configuration ────────────────────────────────────────────────
CACHE_TTL=360                        # キャッシュ有効期間（秒）
CURL_TIMEOUT=5                       # curl タイムアウト（秒）
USAGE_WARN_PCT=80                    # 利用量警告しきい値（%）
USAGE_CRIT_PCT=95                    # 利用量危険しきい値（%）
USAGE_API_URL="https://api.anthropic.com/api/oauth/usage"
USAGE_API_USER_AGENT="ClaudeDesktop/2.0.5"
USAGE_API_VERSION="2023-06-01"
USAGE_API_BETA="oauth-2025-04-20"
# ────────────────────────────────────────────────────────────────
PYTHON_CMD="$(command -v python3 || command -v python)"
if [ -z "$PYTHON_CMD" ]; then
  printf 'statusline-command.sh: python3 or python not found\n' >&2
  exit 1
fi
if ! "$PYTHON_CMD" -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 7) else 1)" 2>/dev/null; then
  printf 'statusline-command.sh: Python 3.7+ is required\n' >&2
  exit 1
fi

input=$(cat)
cwd_real=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')
cwd="${cwd_real/#$HOME/\~}"
model=$(echo "$input" | jq -r '.model.display_name // ""')
ctx_remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')

# Git branch
git_info=""
if git_branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd_real" symbolic-ref --short HEAD 2>/dev/null); then
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
SKY_BLUE=$'\033[38;5;117m'
PINK=$'\033[38;5;213m'
AMBER=$'\033[38;5;179m'
LIGHT_GRAY=$'\033[38;5;246m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

# Color based on model name
model_color() {
  local model_lower
  model_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  case "$model_lower" in
    *haiku*) printf '%s' "$AMBER" ;;
    *sonnet*) printf '%s' "$SKY_BLUE" ;;
    *opus*) printf '%s' "$PINK" ;;
    *) printf '%s' "$MAGENTA" ;;
  esac
}

# Color based on utilization %
usage_color() {
  local pct=$1
  if [ "$pct" -ge "$USAGE_CRIT_PCT" ]; then
    printf '%s' "$RED"
  elif [ "$pct" -ge "$USAGE_WARN_PCT" ]; then
    printf '%s' "$YELLOW"
  else
    printf '%s' "$GREEN"
  fi
}

# Fetch usage from Anthropic API with cache
CACHE_DIR="${HOME}/.claude/cache"
mkdir -p "$CACHE_DIR" 2>/dev/null
CACHE_FILE="${CACHE_DIR}/claude-usage-cache.json"
LOG_FILE="${CACHE_DIR}/claude-usage-api.log"
# On Windows (MINGW/Cygwin), Python cannot read MSYS paths (/c/Users/...).
# Convert to Windows-native paths for use inside Python scripts.
if command -v cygpath >/dev/null 2>&1; then
  CACHE_FILE_PY=$(cygpath -m "$CACHE_FILE")
else
  CACHE_FILE_PY="$CACHE_FILE"
fi
now=$(date +%s)

use_cache=false
if [ -f "$CACHE_FILE" ]; then
  cache_time=$(CACHE_FILE_PY="$CACHE_FILE_PY" "$PYTHON_CMD" -c "import json,os; d=json.load(open(os.environ['CACHE_FILE_PY'])); print(d.get('_ts', 0))" 2>/dev/null || echo 0)
  if [ $(( now - cache_time )) -lt $CACHE_TTL ]; then
    use_cache=true
  fi
fi

five_pct=""
seven_pct=""
five_resets_at=""
seven_resets_at=""
api_error=""

if [ "$use_cache" = true ]; then
  _cache_out=$(CACHE_FILE_PY="$CACHE_FILE_PY" "$PYTHON_CMD" -c "import json,os; d=json.load(open(os.environ['CACHE_FILE_PY'])); print('%s|%s|%s|%s|%s' % (int(d.get('five_hour_pct',-1)),int(d.get('seven_day_pct',-1)),d.get('five_resets_at',''),d.get('seven_resets_at',''),d.get('api_error','')))" 2>/dev/null)
  IFS='|' read -r five_pct seven_pct five_resets_at seven_resets_at api_error <<< "$_cache_out"
else
  # Get OAuth token: try macOS Keychain first, then credentials file (Windows/Linux)
  TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
    | "$PYTHON_CMD" -c "import json,sys; d=json.load(sys.stdin); print(d['claudeAiOauth']['accessToken'])" 2>/dev/null)
  if [ -z "$TOKEN" ]; then
    TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "${HOME}/.claude/.credentials.json" 2>/dev/null)
  fi

  if [ -n "$TOKEN" ]; then
    api_resp=$(curl -s --max-time "$CURL_TIMEOUT" "$USAGE_API_URL" \
      -H "Authorization: Bearer $TOKEN" \
      -H "User-Agent: $USAGE_API_USER_AGENT" \
      -H "anthropic-version: $USAGE_API_VERSION" \
      -H "anthropic-beta: $USAGE_API_BETA" 2>/dev/null)
    curl_exit=$?

    if [ $curl_exit -eq 28 ]; then
      api_error="timeout"
      CACHE_FILE_PY="$CACHE_FILE_PY" "$PYTHON_CMD" -c "import json,time,os,tempfile; _p=os.environ['CACHE_FILE_PY']; _d={'_ts':int(time.time()),'api_error':'timeout'}; _fd,_t=tempfile.mkstemp(dir=os.path.dirname(_p) or '.',prefix='.claude-usage-',suffix='.tmp'); os.write(_fd,json.dumps(_d).encode()); os.close(_fd); os.replace(_t,_p)" 2>/dev/null
      printf '%s [curl_exit=%d] error:timeout\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$curl_exit" >> "$LOG_FILE" 2>/dev/null
    elif [ $curl_exit -ne 0 ]; then
      api_error="unknown"
      CACHE_FILE_PY="$CACHE_FILE_PY" "$PYTHON_CMD" -c "import json,time,os,tempfile; _p=os.environ['CACHE_FILE_PY']; _d={'_ts':int(time.time()),'api_error':'unknown'}; _fd,_t=tempfile.mkstemp(dir=os.path.dirname(_p) or '.',prefix='.claude-usage-',suffix='.tmp'); os.write(_fd,json.dumps(_d).encode()); os.close(_fd); os.replace(_t,_p)" 2>/dev/null
      printf '%s [curl_exit=%d] error:unknown\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$curl_exit" >> "$LOG_FILE" 2>/dev/null
    else
      parsed=$(API_RESP="$api_resp" "$PYTHON_CMD" - <<'PYEOF' 2>/dev/null
import json, sys, os

resp = os.environ.get('API_RESP', '')
try:
    d = json.loads(resp)
except Exception:
    print("error:unknown")
    sys.exit(0)

if 'error' in d:
    err_type = d['error'].get('type', '')
    if 'rate_limit' in err_type or 'usage' in err_type or 'quota' in err_type:
        print("error:limit")
    else:
        print("error:unknown")
    sys.exit(0)

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

      if [[ "$parsed" == error:* ]]; then
        api_error="${parsed#error:}"
        API_ERROR="$api_error" CACHE_FILE_PY="$CACHE_FILE_PY" "$PYTHON_CMD" -c "import json,time,os,tempfile; _p=os.environ['CACHE_FILE_PY']; _d={'_ts':int(time.time()),'api_error':os.environ['API_ERROR']}; _fd,_t=tempfile.mkstemp(dir=os.path.dirname(_p) or '.',prefix='.claude-usage-',suffix='.tmp'); os.write(_fd,json.dumps(_d).encode()); os.close(_fd); os.replace(_t,_p)" 2>/dev/null
        printf '%s [curl_exit=%d] %s resp=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$curl_exit" "$parsed" "$api_resp" >> "$LOG_FILE" 2>/dev/null
      elif [ -n "$parsed" ]; then
        IFS='|' read -r five_pct seven_pct five_resets_at seven_resets_at <<< "$parsed"
        printf '%s [curl_exit=%d] ok 5h=%s%% 7d=%s%%\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$curl_exit" "$five_pct" "$seven_pct" >> "$LOG_FILE" 2>/dev/null
        FIVE_PCT="$five_pct" SEVEN_PCT="$seven_pct" \
        FIVE_RESETS_AT="$five_resets_at" SEVEN_RESETS_AT="$seven_resets_at" \
        CACHE_FILE_PY="$CACHE_FILE_PY" "$PYTHON_CMD" - <<'PYEOF' 2>/dev/null
import json, time, os, tempfile
d = {
  '_ts': int(time.time()),
  'five_hour_pct': int(os.environ['FIVE_PCT']),
  'seven_day_pct': int(os.environ['SEVEN_PCT']),
  'five_resets_at': os.environ['FIVE_RESETS_AT'],
  'seven_resets_at': os.environ['SEVEN_RESETS_AT']
}
_p = os.environ['CACHE_FILE_PY']
_fd, _tmp = tempfile.mkstemp(dir=os.path.dirname(_p) or '.', prefix='.claude-usage-', suffix='.tmp')
with os.fdopen(_fd, 'w') as f:
    json.dump(d, f)
os.replace(_tmp, _p)
PYEOF
      else
        api_error="unknown"
        CACHE_FILE_PY="$CACHE_FILE_PY" "$PYTHON_CMD" -c "import json,time,os,tempfile; _p=os.environ['CACHE_FILE_PY']; _d={'_ts':int(time.time()),'api_error':'unknown'}; _fd,_t=tempfile.mkstemp(dir=os.path.dirname(_p) or '.',prefix='.claude-usage-',suffix='.tmp'); os.write(_fd,json.dumps(_d).encode()); os.close(_fd); os.replace(_t,_p)" 2>/dev/null
        printf '%s [curl_exit=%d] error:unknown (empty parsed) resp=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$curl_exit" "$api_resp" >> "$LOG_FILE" 2>/dev/null
      fi
    fi
  fi
fi

# Calculate remaining time from resets_at ISO string
# Output: "3h21m" if < 24h, "2d" if >= 24h, "" if unavailable
fmt_remaining() {
  local iso_str="$1"
  [ -z "$iso_str" ] && return
  ISO_STR="$iso_str" "$PYTHON_CMD" - <<'PYEOF' 2>/dev/null
import sys, os
from datetime import datetime, timezone, timedelta

iso = os.environ.get('ISO_STR', '')
try:
    dt = datetime.fromisoformat(iso.replace('Z', '+00:00'))
    now = datetime.now(timezone.utc)
    diff = dt - now
    secs = int(diff.total_seconds())
    if secs <= 0:
        print('')
    elif secs < 3600:
        m = secs // 60
        print(f'{m}m')
    elif secs < 36000:
        print(f'{secs / 3600:.1f}h')
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

cwd_base="${cwd##*/}"
cwd_base="${cwd_base##*\\}"
[ -z "$cwd_base" ] && cwd_base="$cwd"

ctx_part=""
if [ -n "$ctx_remaining" ]; then
  ctx_used=$(( 100 - ctx_remaining ))
  ctx_col=$(usage_color "$ctx_used")
  ctx_part="${GRAY}[ctx]${RESET} ${ctx_col}${ctx_used}%${RESET}"
fi

if [ -n "$api_error" ]; then
  case "$api_error" in
    limit)   error_msg="Usage API Rate Limit" ;;
    timeout) error_msg="Timeout" ;;
    *)       error_msg="Unknown Error" ;;
  esac
  five_part="${LIGHT_GRAY}${error_msg}${RESET}"
  seven_part=""
elif [ -n "$five_pct" ] && [ "$five_pct" -ge 0 ] 2>/dev/null; then
  col=$(usage_color "$five_pct")
  five_remaining=$(fmt_remaining "$five_resets_at")
  [ -z "$five_remaining" ] && five_remaining="5h"
  remaining_str=" ${LIGHT_GRAY}(${five_remaining})${RESET}"
  five_part="${GRAY}[5h]${RESET} ${col}${five_pct}%${RESET}${remaining_str}"
  if [ -n "$seven_pct" ] && [ "$seven_pct" -ge 0 ] 2>/dev/null; then
    col=$(usage_color "$seven_pct")
    seven_remaining=$(fmt_remaining "$seven_resets_at")
    remaining_str=""
    [ -n "$seven_remaining" ] && remaining_str=" ${LIGHT_GRAY}(${seven_remaining})${RESET}"
    seven_part="${GRAY}[7d]${RESET} ${col}${seven_pct}%${RESET}${remaining_str}"
  else
    seven_part="${GRAY}[7d] --%${RESET}"
  fi
else
  five_part="${GRAY}[5h] --%${RESET}"
  seven_part="${GRAY}[7d] --%${RESET}"
fi

model_part="$(model_color "$model")${model}${RESET}"
cwd_part="${BOLD}${YELLOW}${cwd_base}${RESET}${CYAN}${git_info}${RESET}"

line=""
[ -n "$ctx_part" ] && line="${ctx_part}"
usage_part="${five_part}${seven_part:+ $seven_part}"
line="${line:+$line }${usage_part} ${model_part} ${cwd_part}"
printf '%s' "$line"
