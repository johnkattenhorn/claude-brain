---
name: brain-diff
description: Preview what would change on the next brain sync. Shows differences between local state and the remote consolidated brain without making any changes.
user-invocable: true
disable-model-invocation: true
allowed-tools: Bash, Read
---

The user wants to see what would change if they ran /brain-sync, without actually syncing.

## Steps

1. Check brain is initialized:
   ```bash
   if [ ! -f ~/.claude/brain-config.json ]; then
     echo "Brain not initialized. Run /brain-init or /brain-join first."
     exit 1
   fi
   ```

2. Fetch latest remote state (without merging):
   ```bash
   git -C ~/.claude/brain-repo fetch origin main 2>/dev/null
   ```

3. Show what the remote has that local doesn't:
   ```bash
   echo "=== Remote changes (would be pulled) ==="
   git -C ~/.claude/brain-repo diff HEAD..origin/main --stat 2>/dev/null || echo "  (up to date or offline)"
   echo ""
   ```

4. Show what local has that remote doesn't:
   ```bash
   echo "=== Local changes (would be pushed) ==="
   MACHINE_ID=$(jq -r '.machine_id' ~/.claude/brain-config.json)

   # Export a fresh snapshot to temp to compare
   TEMP_SNAPSHOT=$(mktemp)
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/export.sh" --output "$TEMP_SNAPSHOT" --quiet --skip-secret-scan 2>/dev/null

   CURRENT_SNAPSHOT=~/.claude/brain-repo/machines/${MACHINE_ID}/brain-snapshot.json
   if [ -f "$CURRENT_SNAPSHOT" ]; then
     # Compare key sections
     for section in declarative.claude_md.content declarative.rules procedural.skills procedural.agents experiential.auto_memory environmental.settings.content; do
       local_val=$(jq -r ".$section // empty" "$TEMP_SNAPSHOT" 2>/dev/null | wc -c)
       remote_val=$(jq -r ".$section // empty" "$CURRENT_SNAPSHOT" 2>/dev/null | wc -c)
       label=$(echo "$section" | cut -d. -f1-2)
       if [ "$local_val" != "$remote_val" ]; then
         echo "  CHANGED: $label (local: ${local_val}b, last pushed: ${remote_val}b)"
       fi
     done
   else
     echo "  (no previous snapshot — full export would be pushed)"
   fi

   rm -f "$TEMP_SNAPSHOT"
   echo ""
   ```

5. Show conflict status:
   ```bash
   echo "=== Conflicts ==="
   CONFLICTS_FILE=~/.claude/brain-conflicts.json
   if [ -f "$CONFLICTS_FILE" ]; then
     COUNT=$(jq '.conflicts | length' "$CONFLICTS_FILE" 2>/dev/null || echo 0)
     if [ "$COUNT" -gt 0 ]; then
       echo "  $COUNT unresolved conflict(s) — run /brain-conflicts to review"
     else
       echo "  None"
     fi
   else
     echo "  None"
   fi
   echo ""
   ```

6. Show machine network status:
   ```bash
   echo "=== Network ==="
   MACHINES_FILE=~/.claude/brain-repo/meta/machines.json
   if [ -f "$MACHINES_FILE" ]; then
     jq -r '.machines[] | "  \(.name) (\(.id)) — last seen: \(.last_sync // "unknown")"' "$MACHINES_FILE" 2>/dev/null
   fi
   ```

7. Summarize: "This is a preview only. Run /brain-sync to apply these changes."
