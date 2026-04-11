#!/usr/bin/env bash
# push.sh — Export brain snapshot and push to Git remote
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

QUIET=false
FORCE=false
SKIP_SECRET_SCAN=false
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=true; BRAIN_QUIET=true; shift ;;
    --force) FORCE=true; shift ;;
    --skip-secret-scan) SKIP_SECRET_SCAN=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) shift ;;
  esac
done

check_dependencies
load_config

machine_id=$(get_config "machine_id")
snapshot_dir="${BRAIN_REPO}/machines/${machine_id}"
snapshot_file="${snapshot_dir}/brain-snapshot.json"

# Delta sync: compute quick hash of source files to skip export if unchanged
if ! $FORCE && ! $DRY_RUN && [ -f "$snapshot_file" ]; then
  old_hash=$(jq -r '.snapshot_hash // "none"' "$snapshot_file" 2>/dev/null)
  # Quick content hash of key source files
  quick_hash=$(cat \
    "${CLAUDE_DIR}/CLAUDE.md" \
    "${CLAUDE_DIR}/settings.json" \
    2>/dev/null | compute_hash)
  # Also hash memory dir modification time
  mem_hash=""
  if [ -d "${CLAUDE_DIR}/projects" ]; then
    mem_hash=$(find "${CLAUDE_DIR}/projects" -name "*.md" -newer "$snapshot_file" 2>/dev/null | wc -l | tr -d ' ')
  fi
  if [ "$mem_hash" = "0" ] && [ -f "$snapshot_file" ]; then
    # Check if any rules/skills/agents changed since last snapshot
    changed_files=$(find \
      "${CLAUDE_DIR}/rules" "${CLAUDE_DIR}/skills" "${CLAUDE_DIR}/agents" \
      -newer "$snapshot_file" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$changed_files" = "0" ]; then
      log_info "No local changes since last export. Skipping."
      exit 0
    fi
  fi
fi

# Export fresh snapshot
mkdir -p "$snapshot_dir"
export_args=(--output "$snapshot_file")
$QUIET && export_args+=(--quiet)
$SKIP_SECRET_SCAN && export_args+=(--skip-secret-scan)
# Apply active profile categories
profile_cats=$(get_profile_categories)
if [ "$profile_cats" != "all" ]; then
  export_args+=(--categories "$profile_cats")
fi
"${SCRIPT_DIR}/export.sh" "${export_args[@]}"

# Check if exported snapshot differs from what's in git
if ! $FORCE && ! $DRY_RUN; then
  if brain_git diff --quiet -- "machines/${machine_id}/" 2>/dev/null; then
    log_info "No changes to push."
    exit 0
  fi
fi

# Dry-run mode: show what would be synced
if $DRY_RUN; then
  log_info "Would sync:"
  brain_git diff --stat -- "machines/${machine_id}/" 2>/dev/null || true
  exit 0
fi

# Update machines.json with last sync time
"${SCRIPT_DIR}/register-machine.sh" "$(get_config remote)"

# Commit and push
brain_git add "machines/${machine_id}/" "meta/machines.json" 2>/dev/null || true
brain_git add "shared/" 2>/dev/null || true
brain_git add "PLUGINS.md" 2>/dev/null || true
brain_git commit -m "Sync: $(get_machine_name) (${machine_id}) at $(now_iso)" 2>/dev/null || {
  log_info "Nothing to commit."
  exit 0
}

# Push with retry (handles concurrent pushes)
if brain_push_with_retry 3 2; then
  # Update local config
  local_tmp=$(brain_mktemp)
  jq --arg ts "$(now_iso)" '.last_push = $ts | .dirty = false' "$BRAIN_CONFIG" > "$local_tmp"
  mv "$local_tmp" "$BRAIN_CONFIG"
  log_info "Brain snapshot pushed."
else
  # Mark dirty for retry on next session start
  local_tmp=$(brain_mktemp)
  jq '.dirty = true' "$BRAIN_CONFIG" > "$local_tmp"
  mv "$local_tmp" "$BRAIN_CONFIG"
  log_warn "Push failed. Marked dirty for retry."
fi
