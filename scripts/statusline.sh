#!/usr/bin/env bash
# statusline.sh — Claude Code status line script for brain sync state
# Reads cached state written by update-status.sh and displays a compact status
# Configure in settings.json: "statusLine": {"type":"command","command":"bash ~/.claude/plugins/cache/claude-brain-sync/.../scripts/statusline.sh"}
cat >/dev/null  # consume stdin (Claude Code sends session JSON)

STATE_FILE="${HOME}/.cache/brain-sync-state.json"

if [ ! -f "$STATE_FILE" ]; then
  echo "Brain: not configured"
  exit 0
fi

STATE=$(cat "$STATE_FILE" 2>/dev/null || echo '{}')

LAST_SYNC=$(echo "$STATE" | jq -r '.last_sync // "never"' 2>/dev/null)
DIRTY=$(echo "$STATE" | jq -r '.dirty // false' 2>/dev/null)
CONFLICTS=$(echo "$STATE" | jq -r '.conflict_count // 0' 2>/dev/null)
MACHINES=$(echo "$STATE" | jq -r '.machine_count // 0' 2>/dev/null)
ERROR=$(echo "$STATE" | jq -r '.sync_error // ""' 2>/dev/null)

# ANSI colors
GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; DIM='\033[2m'; RESET='\033[0m'

# Compute relative time
relative_time() {
  local ts="$1"
  if [ "$ts" = "never" ] || [ "$ts" = "null" ] || [ -z "$ts" ]; then
    echo "never"
    return
  fi
  local sync_epoch now_epoch diff
  sync_epoch=$(date -d "$ts" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || echo "0")
  now_epoch=$(date +%s)
  diff=$((now_epoch - sync_epoch))
  if [ "$diff" -lt 60 ]; then echo "just now"
  elif [ "$diff" -lt 3600 ]; then echo "$((diff / 60))m ago"
  elif [ "$diff" -lt 86400 ]; then echo "$((diff / 3600))h ago"
  else echo "$((diff / 86400))d ago"
  fi
}

SYNC_AGO=$(relative_time "$LAST_SYNC")

# Build status icon
if [ -n "$ERROR" ]; then
  ICON="${RED}!${RESET}"
elif [ "$CONFLICTS" != "0" ] && [ "$CONFLICTS" != "null" ]; then
  ICON="${RED}${CONFLICTS}!${RESET}"
elif [ "$DIRTY" = "true" ]; then
  ICON="${YELLOW}*${RESET}"
else
  ICON="${GREEN}ok${RESET}"
fi

echo -e "Brain [${ICON}] ${DIM}${SYNC_AGO}${RESET} ${DIM}${MACHINES}m${RESET}"
