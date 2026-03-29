---
name: brain-doctor
description: Health check for brain sync. Detects corruption, stale conflicts, missing config, broken git state, and plugin issues.
user-invocable: true
disable-model-invocation: true
allowed-tools: Bash, Read
---

Run a comprehensive health check on the brain sync system and report any issues found.

## Steps

Run each check and collect results. Display a summary at the end with pass/warn/fail status for each.

### 1. Plugin installation check
```bash
echo "=== Brain Doctor ==="
echo ""
ISSUES=0
WARNINGS=0

# Check plugin is properly installed
if [ ! -f "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" ]; then
  echo "FAIL: Plugin not properly installed (missing plugin.json)"
  ISSUES=$((ISSUES + 1))
else
  echo "  ok: Plugin installed"
fi
```

### 2. Brain config check
```bash
CONFIG=~/.claude/brain-config.json
if [ ! -f "$CONFIG" ]; then
  echo "FAIL: brain-config.json missing — run /brain-init or /brain-join"
  ISSUES=$((ISSUES + 1))
else
  # Validate JSON
  if ! jq empty "$CONFIG" 2>/dev/null; then
    echo "FAIL: brain-config.json is corrupted (invalid JSON)"
    ISSUES=$((ISSUES + 1))
  else
    echo "  ok: brain-config.json valid"

    # Check required fields
    for field in machine_id machine_name remote brain_repo_path; do
      val=$(jq -r ".$field // empty" "$CONFIG")
      if [ -z "$val" ]; then
        echo "WARN: brain-config.json missing field: $field"
        WARNINGS=$((WARNINGS + 1))
      fi
    done

    # Check dirty flag
    dirty=$(jq -r '.dirty // false' "$CONFIG")
    if [ "$dirty" = "true" ]; then
      echo "WARN: Brain has unsaved changes (dirty=true). Run /brain-sync."
      WARNINGS=$((WARNINGS + 1))
    fi
  fi
fi
```

### 3. Brain repo check
```bash
BRAIN_REPO=~/.claude/brain-repo
if [ ! -d "$BRAIN_REPO/.git" ]; then
  echo "FAIL: brain-repo missing or not a git repo"
  ISSUES=$((ISSUES + 1))
else
  echo "  ok: brain-repo exists"

  # Check remote is reachable
  if git -C "$BRAIN_REPO" ls-remote origin HEAD &>/dev/null; then
    echo "  ok: Remote reachable"
  else
    echo "WARN: Cannot reach remote — offline or auth issue"
    WARNINGS=$((WARNINGS + 1))
  fi

  # Check for uncommitted changes
  if [ -n "$(git -C "$BRAIN_REPO" status --porcelain 2>/dev/null)" ]; then
    echo "WARN: brain-repo has uncommitted changes"
    WARNINGS=$((WARNINGS + 1))
  fi

  # Check for merge conflicts
  if [ -n "$(git -C "$BRAIN_REPO" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
    echo "FAIL: brain-repo has unresolved git merge conflicts"
    ISSUES=$((ISSUES + 1))
  fi
fi
```

### 4. Snapshot check
```bash
MACHINE_ID=$(jq -r '.machine_id // empty' "$CONFIG" 2>/dev/null)
SNAPSHOT="$BRAIN_REPO/machines/$MACHINE_ID/brain-snapshot.json"
if [ -z "$MACHINE_ID" ]; then
  echo "FAIL: No machine ID configured"
  ISSUES=$((ISSUES + 1))
elif [ ! -f "$SNAPSHOT" ]; then
  echo "WARN: No snapshot for this machine yet — run /brain-sync"
  WARNINGS=$((WARNINGS + 1))
else
  if ! jq empty "$SNAPSHOT" 2>/dev/null; then
    echo "FAIL: Machine snapshot is corrupted (invalid JSON)"
    ISSUES=$((ISSUES + 1))
  else
    echo "  ok: Machine snapshot valid"

    # Check snapshot age
    EXPORTED=$(jq -r '.exported_at // empty' "$SNAPSHOT")
    if [ -n "$EXPORTED" ]; then
      EXPORT_TS=$(date -d "$EXPORTED" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$EXPORTED" +%s 2>/dev/null || echo 0)
      NOW=$(date +%s)
      AGE_DAYS=$(( (NOW - EXPORT_TS) / 86400 ))
      if [ "$AGE_DAYS" -gt 7 ]; then
        echo "WARN: Snapshot is ${AGE_DAYS} days old — consider running /brain-sync"
        WARNINGS=$((WARNINGS + 1))
      fi
    fi
  fi
fi
```

### 5. Consolidated brain check
```bash
CONSOLIDATED="$BRAIN_REPO/consolidated/brain.json"
if [ -f "$CONSOLIDATED" ]; then
  if ! jq empty "$CONSOLIDATED" 2>/dev/null; then
    echo "FAIL: Consolidated brain is corrupted (invalid JSON)"
    ISSUES=$((ISSUES + 1))
  else
    echo "  ok: Consolidated brain valid"
    SCHEMA=$(jq -r '.schema_version // "unknown"' "$CONSOLIDATED")
    if [ "$SCHEMA" != "1.0.0" ]; then
      echo "WARN: Unexpected schema version: $SCHEMA (expected 1.0.0)"
      WARNINGS=$((WARNINGS + 1))
    fi
  fi
else
  echo "WARN: No consolidated brain yet — run /brain-sync"
  WARNINGS=$((WARNINGS + 1))
fi
```

### 6. Conflicts check
```bash
CONFLICTS=~/.claude/brain-conflicts.json
if [ -f "$CONFLICTS" ]; then
  if ! jq empty "$CONFLICTS" 2>/dev/null; then
    echo "FAIL: brain-conflicts.json is corrupted"
    ISSUES=$((ISSUES + 1))
  else
    COUNT=$(jq '.conflicts | length' "$CONFLICTS" 2>/dev/null || echo 0)
    if [ "$COUNT" -gt 0 ]; then
      echo "WARN: $COUNT unresolved conflict(s) — run /brain-conflicts"
      WARNINGS=$((WARNINGS + 1))
    else
      echo "  ok: No conflicts"
    fi
  fi
else
  echo "  ok: No conflicts file"
fi
```

### 7. Machines registry check
```bash
MACHINES="$BRAIN_REPO/meta/machines.json"
if [ -f "$MACHINES" ]; then
  if ! jq empty "$MACHINES" 2>/dev/null; then
    echo "FAIL: machines.json is corrupted"
    ISSUES=$((ISSUES + 1))
  else
    MCOUNT=$(jq '.machines | length' "$MACHINES" 2>/dev/null || echo 0)
    echo "  ok: $MCOUNT machine(s) in network"

    # Check for orphaned snapshots (snapshot exists but machine not registered)
    for snap_dir in "$BRAIN_REPO"/machines/*/; do
      if [ -d "$snap_dir" ]; then
        SNAP_ID=$(basename "$snap_dir")
        if ! jq -e --arg id "$SNAP_ID" '.machines[] | select(.id == $id)' "$MACHINES" &>/dev/null; then
          echo "WARN: Orphaned snapshot for unregistered machine: $SNAP_ID"
          WARNINGS=$((WARNINGS + 1))
        fi
      fi
    done
  fi
fi
```

### 8. Dependencies check
```bash
echo ""
echo "=== Dependencies ==="
for cmd in git jq; do
  if command -v "$cmd" &>/dev/null; then
    echo "  ok: $cmd ($($cmd --version 2>&1 | head -1))"
  else
    echo "FAIL: $cmd not installed"
    ISSUES=$((ISSUES + 1))
  fi
done

if command -v age &>/dev/null; then
  echo "  ok: age (encryption available)"
else
  echo "  --: age not installed (encryption unavailable)"
fi

if command -v claude &>/dev/null; then
  echo "  ok: claude CLI (semantic merge available)"
else
  echo "WARN: claude CLI not found (semantic merge will use fallback)"
  WARNINGS=$((WARNINGS + 1))
fi
```

### 9. Summary
```bash
echo ""
echo "=== Summary ==="
if [ "$ISSUES" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
  echo "All checks passed. Brain is healthy."
elif [ "$ISSUES" -eq 0 ]; then
  echo "$WARNINGS warning(s), 0 errors. Brain is functional but check the warnings above."
else
  echo "$ISSUES error(s), $WARNINGS warning(s). Brain needs attention — fix the errors above."
fi
```
