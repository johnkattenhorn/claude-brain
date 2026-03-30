#!/usr/bin/env bash
# update-status.sh — Write brain sync state for status line consumption
# Called after push/pull operations to update the cached state file
# Includes API call tracking, kill-switch, and circuit breaker status for HUD
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

STATE_FILE="${HOME}/.cache/brain-sync-state.json"
mkdir -p "$(dirname "$STATE_FILE")"

# Gather current state
last_push="never"
last_pull="never"
dirty=false
conflict_count=0
machine_count=0
sync_error=""

if [ -f "$BRAIN_CONFIG" ]; then
  last_push=$(jq -r '.last_push // "never"' "$BRAIN_CONFIG")
  last_pull=$(jq -r '.last_pull // "never"' "$BRAIN_CONFIG")
  dirty=$(jq -r '.dirty // false' "$BRAIN_CONFIG")
fi

# Count unresolved conflicts
conflicts_file="${HOME}/.claude/brain-conflicts.json"
if [ -f "$conflicts_file" ]; then
  conflict_count=$(jq '.conflicts | length' "$conflicts_file" 2>/dev/null || echo 0)
fi

# Count machines in network
machines_file="${BRAIN_REPO}/meta/machines.json"
if [ -f "$machines_file" ]; then
  machine_count=$(jq '.machines | length' "$machines_file" 2>/dev/null || echo 0)
fi

# Check for sync errors (passed as argument)
if [ "${1:-}" = "--error" ]; then
  sync_error="${2:-unknown error}"
fi

# Compute relative time for last sync
last_sync="never"
if [ "$last_pull" != "never" ] && [ "$last_pull" != "null" ]; then
  last_sync="$last_pull"
elif [ "$last_push" != "never" ] && [ "$last_push" != "null" ]; then
  last_sync="$last_push"
fi

# ── API Protection Status ────────────────────────────────────────────────────
kill_switch_active=false
kill_switch_reason=""
if [ -f "$BRAIN_KILL_SWITCH" ]; then
  kill_switch_active=$(jq -r '.active // false' "$BRAIN_KILL_SWITCH" 2>/dev/null || echo "false")
  if [ "$kill_switch_active" = "true" ]; then
    kill_switch_reason=$(jq -r '.reason // "unknown"' "$BRAIN_KILL_SWITCH" 2>/dev/null || echo "unknown")
  fi
fi

circuit_breaker_state="closed"
circuit_breaker_failures=0
if [ -f "$BRAIN_CIRCUIT_BREAKER" ]; then
  circuit_breaker_state=$(jq -r '.state // "closed"' "$BRAIN_CIRCUIT_BREAKER" 2>/dev/null || echo "closed")
  circuit_breaker_failures=$(jq -r '.consecutive_failures // 0' "$BRAIN_CIRCUIT_BREAKER" 2>/dev/null || echo "0")
fi

# Count recent API calls (last hour)
api_calls_last_hour=0
if [ -f "$BRAIN_API_LOG" ]; then
  one_hour_ago=$(date -u -v-1H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "1 hour ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
  if [ -n "$one_hour_ago" ]; then
    api_calls_last_hour=$(awk -v cutoff="$one_hour_ago" '
      { if (match($0, /"timestamp":"([^"]+)"/, m) && m[1] >= cutoff) count++ }
      END { print count+0 }
    ' "$BRAIN_API_LOG" 2>/dev/null || echo "0")
  fi
fi

# Last API call info
last_api_caller=""
last_api_status=""
last_api_time=""
if [ -f "$BRAIN_API_LOG" ]; then
  last_api_line=$(tail -n 1 "$BRAIN_API_LOG" 2>/dev/null || echo "")
  if [ -n "$last_api_line" ]; then
    last_api_caller=$(echo "$last_api_line" | jq -r '.caller // ""' 2>/dev/null || echo "")
    last_api_status=$(echo "$last_api_line" | jq -r '.status // ""' 2>/dev/null || echo "")
    last_api_time=$(echo "$last_api_line" | jq -r '.timestamp // ""' 2>/dev/null || echo "")
  fi
fi

# Write state (with API protection fields for HUD)
jq -n \
  --arg last_sync "$last_sync" \
  --arg last_push "$last_push" \
  --arg last_pull "$last_pull" \
  --argjson dirty "$dirty" \
  --argjson conflict_count "$conflict_count" \
  --argjson machine_count "$machine_count" \
  --arg sync_error "$sync_error" \
  --arg updated_at "$(now_iso)" \
  --argjson kill_switch_active "$kill_switch_active" \
  --arg kill_switch_reason "$kill_switch_reason" \
  --arg circuit_breaker_state "$circuit_breaker_state" \
  --argjson circuit_breaker_failures "$circuit_breaker_failures" \
  --argjson api_calls_last_hour "$api_calls_last_hour" \
  --arg last_api_caller "$last_api_caller" \
  --arg last_api_status "$last_api_status" \
  --arg last_api_time "$last_api_time" \
  '{
    last_sync: $last_sync,
    last_push: $last_push,
    last_pull: $last_pull,
    dirty: $dirty,
    conflict_count: $conflict_count,
    machine_count: $machine_count,
    sync_error: $sync_error,
    updated_at: $updated_at,
    api_protection: {
      kill_switch_active: $kill_switch_active,
      kill_switch_reason: $kill_switch_reason,
      circuit_breaker_state: $circuit_breaker_state,
      circuit_breaker_failures: $circuit_breaker_failures,
      api_calls_last_hour: $api_calls_last_hour,
      last_api_caller: $last_api_caller,
      last_api_status: $last_api_status,
      last_api_time: $last_api_time
    }
  }' > "$STATE_FILE"
