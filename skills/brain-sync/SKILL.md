---
name: brain-sync
description: Manually sync brain with remote. Exports local state, pushes to remote, pulls updates from other machines, merges, and applies. Use --dry-run to preview.
user-invocable: true
disable-model-invocation: true
argument-hint: "[--dry-run]"
allowed-tools: Bash, Read, Write, Edit
---

The user wants to manually trigger a full brain sync cycle.

If `$ARGUMENTS` contains `--dry-run`, run in preview mode (no changes made).

## Steps

1. Check that brain is initialized:
   ```bash
   if [ ! -f ~/.claude/brain-config.json ]; then
     echo "Brain not initialized. Run /brain-init first."
     exit 1
   fi
   ```

2. If `--dry-run` is in `$ARGUMENTS`, run preview mode:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/push.sh" --dry-run
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/pull.sh" --dry-run
   ```
   Then stop — don't make any changes.

3. Otherwise, push local changes:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/push.sh"
   ```

4. Pull and merge remote changes:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/pull.sh" --auto-merge
   ```

5. Update status line state:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh"
   ```

6. Show the sync result summary. Check:
   - What changed (new skills, merged memory, updated settings)
   - Any conflicts that need resolution
   - Updated sync timestamps

7. If there are conflicts, suggest: "Run /brain-conflicts to review and resolve."
