---
name: brain-profile
description: Manage sync profiles. List, switch, or create profiles that control which brain categories sync on this machine.
user-invocable: true
disable-model-invocation: true
argument-hint: "[list | set <name> | create <name> <categories> | delete <name>]"
allowed-tools: Bash, Read, Write, Edit
---

Manage sync profiles for this machine. Profiles control which brain categories are synced.

Available categories: `memory`, `claude_md`, `rules`, `skills`, `agents`, `output_styles`, `settings`

## Steps

Parse `$ARGUMENTS` to determine the subcommand.

### `/brain-profile` or `/brain-profile list`

Show available profiles and which is active:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/common.sh"
ACTIVE=$(get_active_profile)

echo "=== Sync Profiles ==="
echo ""

# Show built-in profiles from defaults.json
echo "Built-in:"
jq -r '.profiles // {} | to_entries[] | "  \(.key): \(.value.categories) — \(.value.description // "")"' "${PLUGIN_ROOT}/config/defaults.json" 2>/dev/null

# Show user-defined profiles from brain-config.json
if [ -f "$BRAIN_CONFIG" ]; then
  USER_PROFILES=$(jq -r '.profiles // {} | keys[]' "$BRAIN_CONFIG" 2>/dev/null)
  if [ -n "$USER_PROFILES" ]; then
    echo ""
    echo "Custom:"
    jq -r '.profiles // {} | to_entries[] | "  \(.key): \(.value.categories) — \(.value.description // "")"' "$BRAIN_CONFIG" 2>/dev/null
  fi
fi

echo ""
echo "Active profile: $ACTIVE"
echo ""
echo "Usage:"
echo "  /brain-profile set <name>              — switch active profile"
echo "  /brain-profile create <name> <cats>     — create custom profile"
echo "  /brain-profile delete <name>            — delete custom profile"
```

### `/brain-profile set <name>`

Set the active profile:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/common.sh"
PROFILE_NAME="<the name from arguments>"

# Verify profile exists
if ! resolve_profile "$PROFILE_NAME" >/dev/null 2>&1; then
  echo "Profile '$PROFILE_NAME' not found. Run /brain-profile list to see available profiles."
  exit 1
fi

CATS=$(resolve_profile "$PROFILE_NAME")
TMP=$(mktemp)
jq --arg p "$PROFILE_NAME" '.active_profile = $p' "$BRAIN_CONFIG" > "$TMP" && mv "$TMP" "$BRAIN_CONFIG"
echo "Active profile set to: $PROFILE_NAME (categories: $CATS)"
echo "Next sync will use this profile."
```

### `/brain-profile create <name> <categories>`

Create a custom profile. Categories is a comma-separated list.

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/common.sh"
PROFILE_NAME="<name>"
CATEGORIES="<comma-separated categories>"

# Validate categories
VALID="memory,claude_md,rules,skills,agents,output_styles,settings"
for cat in $(echo "$CATEGORIES" | tr ',' ' '); do
  if ! echo ",$VALID," | grep -q ",$cat,"; then
    echo "Invalid category: $cat"
    echo "Valid categories: $VALID"
    exit 1
  fi
done

# Ask for optional description
# Add to brain-config.json
TMP=$(mktemp)
jq --arg name "$PROFILE_NAME" --arg cats "$CATEGORIES" --arg desc "<description>" \
  '.profiles[$name] = {categories: $cats, description: $desc}' "$BRAIN_CONFIG" > "$TMP" && mv "$TMP" "$BRAIN_CONFIG"

echo "Created profile: $PROFILE_NAME (categories: $CATEGORIES)"
```

### `/brain-profile delete <name>`

Delete a custom profile (can't delete built-in ones):

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/common.sh"
PROFILE_NAME="<name>"

# Check it's not a built-in
if jq -e --arg p "$PROFILE_NAME" '.profiles[$p]' "${PLUGIN_ROOT}/config/defaults.json" &>/dev/null; then
  echo "Cannot delete built-in profile: $PROFILE_NAME"
  exit 1
fi

TMP=$(mktemp)
jq --arg p "$PROFILE_NAME" 'del(.profiles[$p])' "$BRAIN_CONFIG" > "$TMP" && mv "$TMP" "$BRAIN_CONFIG"

# If this was the active profile, reset to full
ACTIVE=$(get_active_profile)
if [ "$ACTIVE" = "$PROFILE_NAME" ]; then
  TMP=$(mktemp)
  jq '.active_profile = "full"' "$BRAIN_CONFIG" > "$TMP" && mv "$TMP" "$BRAIN_CONFIG"
  echo "Active profile reset to: full"
fi

echo "Deleted profile: $PROFILE_NAME"
```
