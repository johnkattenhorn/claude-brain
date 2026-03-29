#!/usr/bin/env bash
# update-status.sh — Write brain sync state for status line consumption
# Called after push/pull operations to update the cached state file
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

# Write state
jq -n \
  --arg last_sync "$last_sync" \
  --arg last_push "$last_push" \
  --arg last_pull "$last_pull" \
  --argjson dirty "$dirty" \
  --argjson conflict_count "$conflict_count" \
  --argjson machine_count "$machine_count" \
  --arg sync_error "$sync_error" \
  --arg updated_at "$(now_iso)" \
  '{
    last_sync: $last_sync,
    last_push: $last_push,
    last_pull: $last_pull,
    dirty: $dirty,
    conflict_count: $conflict_count,
    machine_count: $machine_count,
    sync_error: $sync_error,
    updated_at: $updated_at
  }' > "$STATE_FILE"
