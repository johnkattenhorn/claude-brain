#!/usr/bin/env bash
# common.sh — Shared utilities for claude-brain
set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────────────
CLAUDE_DIR="${CLAUDE_DIR:-${HOME}/.claude}"
CLAUDE_JSON="${CLAUDE_JSON:-${HOME}/.claude.json}"
BRAIN_CONFIG="${BRAIN_CONFIG:-${CLAUDE_DIR}/brain-config.json}"
BRAIN_REPO="${BRAIN_REPO:-${CLAUDE_DIR}/brain-repo}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEFAULTS_FILE="${PLUGIN_ROOT}/config/defaults.json"

# ── Temp File Management ──────────────────────────────────────────────────────
# Track temp files for cleanup on exit/error
_BRAIN_TEMP_FILES=()

brain_mktemp() {
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/claude-brain-XXXXXX")
  chmod 600 "$tmp"
  _BRAIN_TEMP_FILES+=("$tmp")
  echo "$tmp"
}

_brain_cleanup_temps() {
  for f in "${_BRAIN_TEMP_FILES[@]:-}"; do
    rm -f "$f" 2>/dev/null || true
  done
}

trap _brain_cleanup_temps EXIT

# ── OS Detection ───────────────────────────────────────────────────────────────
detect_os() {
  case "$(uname -s)" in
    Linux*)  
      # Check for WSL
      if [ -f /proc/version ] && grep -qi microsoft /proc/version; then
        echo "wsl"
      else
        echo "linux"
      fi
      ;;
    Darwin*) echo "macos" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *)       echo "unknown" ;;
  esac
}

OS="$(detect_os)"

# WSL-specific path handling
is_wsl() {
  [ "$OS" = "wsl" ]
}

# Convert Windows paths to WSL paths if needed
normalize_path() {
  local path="$1"
  if is_wsl && echo "$path" | grep -q '^[A-Za-z]:'; then
    # Convert C:\Users\... to /mnt/c/Users/...
    # Use tr for lowercase (portable — GNU sed \L doesn't work on macOS/BSD)
    local drive_letter
    drive_letter=$(echo "$path" | cut -c1 | tr '[:upper:]' '[:lower:]')
    echo "$path" | sed "s|^[A-Za-z]:|/mnt/${drive_letter}|" | sed 's|\\|/|g'
  else
    echo "$path"
  fi
}

# Get the appropriate home directory
get_user_home() {
  if is_wsl && [ -n "${USERPROFILE:-}" ]; then
    # In WSL, prefer Windows user profile for consistency
    normalize_path "$USERPROFILE"
  else
    echo "$HOME"
  fi
}

# ── JSON Query (requires jq) ───────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required. Install: apt install jq / brew install jq" >&2
  exit 1
fi

json_query() {
  # Usage: json_query '.field.subfield' < input.json
  local filter="$1"
  jq -r "$filter"
}

json_build() {
  # Build JSON from arguments using jq
  # Usage: json_build --arg key value --arg key2 value2 'template'
  jq "$@"
}

json_set() {
  # Set a key in a JSON file
  # Usage: json_set file.json '.key' 'value'
  local file="$1" path="$2" value="$3"
  local tmp
  tmp=$(brain_mktemp)
  jq --argjson val "$value" "${path} = \$val" "$file" > "$tmp" && mv "$tmp" "$file"
}

# ── Hashing ────────────────────────────────────────────────────────────────────
compute_hash() {
  # Compute SHA256 hash of stdin
  if command -v sha256sum &>/dev/null; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum &>/dev/null; then
    shasum -a 256 | cut -d' ' -f1
  elif command -v python3 &>/dev/null; then
    python3 -c "import sys,hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())"
  else
    echo "ERROR: No hash utility found." >&2
    return 1
  fi
}

file_hash() {
  # Compute SHA256 hash of a file
  local file="$1"
  if [ -f "$file" ]; then
    compute_hash < "$file"
  else
    echo "null"
  fi
}

# ── Machine ID ─────────────────────────────────────────────────────────────────
generate_machine_id() {
  # Generate an 8-char hex ID
  if [ -f /dev/urandom ]; then
    head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n'
  elif command -v python3 &>/dev/null; then
    python3 -c "import secrets; print(secrets.token_hex(4))"
  else
    date +%s | compute_hash | head -c 8
  fi
}

get_machine_id() {
  if [ -f "$BRAIN_CONFIG" ]; then
    json_query '.machine_id' < "$BRAIN_CONFIG"
  else
    echo ""
  fi
}

get_machine_name() {
  # Allow user-configured name, fall back to hostname
  if [ -f "$BRAIN_CONFIG" ]; then
    local custom_name
    custom_name=$(json_query '.machine_name' < "$BRAIN_CONFIG" 2>/dev/null || echo "")
    if [ -n "$custom_name" ] && [ "$custom_name" != "null" ]; then
      echo "$custom_name"
      return
    fi
  fi
  hostname 2>/dev/null || echo "unknown"
}

# ── Brain Config ───────────────────────────────────────────────────────────────
is_initialized() {
  [ -f "$BRAIN_CONFIG" ] && [ -d "$BRAIN_REPO/.git" ]
}

load_config() {
  if [ ! -f "$BRAIN_CONFIG" ]; then
    echo "ERROR: Brain not initialized. Run /brain-init first." >&2
    return 1
  fi
}

get_config() {
  local key="$1"
  json_query ".$key" < "$BRAIN_CONFIG"
}

# ── Git Operations ─────────────────────────────────────────────────────────────
brain_git() {
  git -C "$BRAIN_REPO" "$@"
}

brain_push_with_retry() {
  local max_attempts="${1:-3}"
  local base_delay="${2:-2}"
  local attempt=1

  while [ "$attempt" -le "$max_attempts" ]; do
    if brain_git push origin main 2>/dev/null; then
      return 0
    fi

    if [ "$attempt" -lt "$max_attempts" ]; then
      # Exponential backoff: 2s, 4s, 8s...
      local delay=$(( base_delay * (2 ** (attempt - 1)) ))
      log_warn "Push attempt ${attempt}/${max_attempts} failed. Retrying in ${delay}s..."
      # Pull rebase to incorporate remote changes before retry
      brain_git pull --rebase origin main 2>/dev/null || {
        brain_git rebase --abort 2>/dev/null || true
        log_warn "Rebase failed during push retry. Skipping rebase."
      }
      sleep "$delay"
    fi
    attempt=$((attempt + 1))
  done

  log_warn "Push failed after $max_attempts attempts."
  return 1
}

# ── URL Validation ─────────────────────────────────────────────────────────────
validate_remote_url() {
  # Warn if the remote URL appears to be a public repo
  local url="$1"

  # Check for common public patterns
  if echo "$url" | grep -qiE '^https?://(github\.com|gitlab\.com|bitbucket\.org)'; then
    log_warn "HTTPS URL detected. Make sure this repository is PRIVATE."
    log_warn "Your brain data (memory, skills, settings) will be stored there."

    # Try to check visibility via GitHub API if it looks like a github URL
    local repo_path
    repo_path=$(echo "$url" | sed -E 's|https?://github\.com/||; s|\.git$||')
    if command -v curl &>/dev/null && echo "$url" | grep -q "github.com"; then
      local visibility
      visibility=$(curl -s -o /dev/null -w "%{http_code}" "https://api.github.com/repos/${repo_path}" 2>/dev/null || echo "000")
      if [ "$visibility" = "200" ]; then
        log_warn "WARNING: This GitHub repository appears to be PUBLIC!"
        log_warn "Your brain contains sensitive configuration. Use a PRIVATE repo."
        log_warn "To make it private: https://github.com/${repo_path}/settings"
        return 1
      fi
    fi
  fi

  if echo "$url" | grep -qE '^git@|^ssh://'; then
    log_info "SSH URL detected (typically private). Good."
  fi

  return 0
}

# ── Logging ────────────────────────────────────────────────────────────────────
brain_log() {
  local level="$1"
  shift
  if [ "${BRAIN_QUIET:-false}" != "true" ]; then
    echo "[claude-brain] $level: $*" >&2
  fi
}

log_info() { brain_log "INFO" "$@"; }
log_warn() { brain_log "WARN" "$@"; }
log_error() { brain_log "ERROR" "$@"; }

append_merge_log() {
  local action="$1" summary="$2"
  local log_file="${BRAIN_REPO}/meta/merge-log.json"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local machine_id
  machine_id=$(get_machine_id)
  local machine_name
  machine_name=$(get_machine_name)

  if [ ! -f "$log_file" ]; then
    echo '{"entries":[]}' > "$log_file"
  fi

  local tmp
  tmp=$(brain_mktemp)
  jq --arg ts "$timestamp" \
     --arg mid "$machine_id" \
     --arg mn "$machine_name" \
     --arg act "$action" \
     --arg sum "$summary" \
     '.entries = [{"timestamp":$ts,"machine_id":$mid,"machine_name":$mn,"action":$act,"summary":$sum}] + .entries | .entries = .entries[:200]' \
     "$log_file" > "$tmp" && mv "$tmp" "$log_file"
}

# ── Timestamp ──────────────────────────────────────────────────────────────────
now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# ── Dependency Check ───────────────────────────────────────────────────────────
check_dependencies() {
  local missing=()

  if ! command -v git &>/dev/null; then
    missing+=("git")
  fi

  if ! command -v jq &>/dev/null; then
    missing+=("jq")
  fi

  # Check age if encryption is enabled
  if is_initialized && encryption_enabled && ! command -v age &>/dev/null; then
    missing+=("age (for encryption)")
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: Missing dependencies: ${missing[*]}" >&2
    echo "Install them before using claude-brain." >&2
    echo "age can be installed from: https://github.com/FiloSottile/age" >&2
    return 1
  fi
}

# ── Age Encryption ────────────────────────────────────────────────────────────
encryption_enabled() {
  if [ -f "$BRAIN_CONFIG" ]; then
    local enabled
    enabled=$(jq -r '.encryption.enabled // false' "$BRAIN_CONFIG")
    [ "$enabled" = "true" ]
  else
    false
  fi
}

get_age_identity() {
  if [ -f "$BRAIN_CONFIG" ]; then
    jq -r '.encryption.identity // "~/.claude/brain-age-key.txt"' "$BRAIN_CONFIG" | sed "s|~|$HOME|"
  else
    echo "${HOME}/.claude/brain-age-key.txt"
  fi
}

get_age_recipients() {
  if [ -f "$BRAIN_CONFIG" ]; then
    jq -r '.encryption.recipients // "~/.claude/brain-repo/meta/recipients.txt"' "$BRAIN_CONFIG" | sed "s|~|$HOME|"
  else
    echo "${BRAIN_REPO}/meta/recipients.txt"
  fi
}

generate_age_keypair() {
  local identity_file="$1"
  local recipients_file="$2"
  
  if ! command -v age-keygen &>/dev/null; then
    log_error "age-keygen not found. Install age from https://github.com/FiloSottile/age"
    return 1
  fi
  
  mkdir -p "$(dirname "$identity_file")" "$(dirname "$recipients_file")"
  
  # Generate keypair
  age-keygen -o "$identity_file" 2>/dev/null || {
    log_error "Failed to generate age keypair"
    return 1
  }
  
  # Extract public key to recipients file
  grep "# public key:" "$identity_file" | cut -d' ' -f4 > "$recipients_file"
  chmod 600 "$identity_file"
  chmod 644 "$recipients_file"
  
  log_info "Generated age keypair:"
  log_info "  Identity (private): $identity_file"
  log_info "  Recipients (public): $recipients_file"
}

encrypt_content() {
  local content="$1"
  local recipients_file
  recipients_file=$(get_age_recipients)
  
  if [ ! -f "$recipients_file" ]; then
    log_error "Age recipients file not found: $recipients_file"
    return 1
  fi
  
  echo "$content" | age -R "$recipients_file" 2>/dev/null || {
    log_error "Failed to encrypt content"
    return 1
  }
}

decrypt_content() {
  local encrypted_content="$1"
  local identity_file
  identity_file=$(get_age_identity)
  
  if [ ! -f "$identity_file" ]; then
    log_error "Age identity file not found: $identity_file"
    return 1
  fi
  
  echo "$encrypted_content" | age -d -i "$identity_file" 2>/dev/null || {
    log_error "Failed to decrypt content"
    return 1
  }
}

is_encrypted_content() {
  local content="$1"
  # Check for age armor header
  echo "$content" | head -1 | grep -q "^-----BEGIN AGE ENCRYPTED FILE-----"
}

encrypt_file() {
  local input_file="$1"
  local output_file="$2"
  local recipients_file
  recipients_file=$(get_age_recipients)
  
  if [ ! -f "$recipients_file" ]; then
    log_error "Age recipients file not found: $recipients_file"
    return 1
  fi
  
  age -R "$recipients_file" -o "$output_file" "$input_file" 2>/dev/null || {
    log_error "Failed to encrypt file: $input_file"
    return 1
  }
}

decrypt_file() {
  local input_file="$1"
  local output_file="$2"
  local identity_file
  identity_file=$(get_age_identity)
  
  if [ ! -f "$identity_file" ]; then
    log_error "Age identity file not found: $identity_file"
    return 1
  fi
  
  age -d -i "$identity_file" -o "$output_file" "$input_file" 2>/dev/null || {
    log_error "Failed to decrypt file: $input_file"
    return 1
  }
}

# ── Secret Scanning ──────────────────────────────────────────────────────────
# Scans text for common secret patterns and warns the user
SECRET_PATTERNS=(
  'sk-[a-zA-Z0-9]{20,}'                           # OpenAI/Anthropic API keys
  'key-[a-zA-Z0-9]{20,}'                          # Generic API keys
  'AKIA[0-9A-Z]{16}'                              # AWS access key IDs
  'ghp_[a-zA-Z0-9]{20,}'                          # GitHub personal access tokens
  'gho_[a-zA-Z0-9]{20,}'                          # GitHub OAuth tokens
  'github_pat_[a-zA-Z0-9_]{22,}'                  # GitHub fine-grained tokens
  'glpat-[a-zA-Z0-9]{20,}'                        # GitLab personal access tokens
  'xoxb-[0-9]{10,}-[a-zA-Z0-9]{20,}'              # Slack bot tokens
  'xoxp-[0-9]{10,}-[a-zA-Z0-9]{20,}'              # Slack user tokens
  'Bearer [a-zA-Z0-9._+/=-]{20,}'                 # Bearer tokens
  'postgres(ql)?://[^:]+:[^@]+@'                   # PostgreSQL connection strings
  'mysql://[^:]+:[^@]+@'                           # MySQL connection strings
  'mongodb(\+srv)?://[^:]+:[^@]+@'                 # MongoDB connection strings
  'redis://:[^@]+@'                                # Redis connection strings
  'password[" ]*[:=][" ]*[^ ]{8,}'                # Password assignments
  'secret[" ]*[:=][" ]*[^ ]{8,}'                  # Secret assignments
  'token[" ]*[:=][" ]*[a-zA-Z0-9._]{20,}'         # Token assignments
  'PRIVATE KEY-----'                               # Private keys
)

scan_for_secrets() {
  # Scans content from stdin for common secret patterns
  # Returns 0 if no secrets found, 1 if secrets detected
  # Outputs warnings to stderr
  local content
  content=$(cat)
  local found=0

  for pattern in "${SECRET_PATTERNS[@]}"; do
    local matches
    matches=$(echo "$content" | grep -oEi "$pattern" 2>/dev/null | head -5 || true)
    if [ -n "$matches" ]; then
      if [ "$found" -eq 0 ]; then
        log_warn "POTENTIAL SECRETS DETECTED in brain data:"
        found=1
      fi
      # Show redacted match
      while IFS= read -r match; do
        local redacted
        redacted=$(echo "$match" | head -c 12)
        log_warn "  Pattern match: ${redacted}... (redacted)"
      done <<< "$matches"
    fi
  done

  if [ "$found" -eq 1 ]; then
    log_warn "Review your memory files and remove secrets before syncing."
    log_warn "Use --skip-secret-scan to suppress this warning."
    return 1
  fi
  return 0
}

# ── Size Guards ──────────────────────────────────────────────────────────────
MAX_SNAPSHOT_SIZE_BYTES=$((10 * 1024 * 1024))  # 10 MB
MAX_SINGLE_FILE_BYTES=$((1 * 1024 * 1024))     # 1 MB

check_file_size() {
  local file="$1" max="${2:-$MAX_SINGLE_FILE_BYTES}"
  if [ -f "$file" ]; then
    local size
    size=$(wc -c < "$file" | tr -d ' ')
    if [ "$size" -gt "$max" ]; then
      log_warn "File $file is very large (${size} bytes). This may cause issues."
      return 1
    fi
  fi
  return 0
}

# ── Backup / Restore ─────────────────────────────────────────────────────────
BACKUP_DIR="${CLAUDE_DIR}/brain-backups"

backup_before_import() {
  # Create a timestamped backup of current brain state before importing
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local backup_path="${BACKUP_DIR}/${timestamp}"
  mkdir -p "$backup_path"

  # Back up key files
  [ -f "${CLAUDE_DIR}/CLAUDE.md" ] && cp "${CLAUDE_DIR}/CLAUDE.md" "${backup_path}/" 2>/dev/null || true
  [ -d "${CLAUDE_DIR}/rules" ] && cp -r "${CLAUDE_DIR}/rules" "${backup_path}/" 2>/dev/null || true
  [ -d "${CLAUDE_DIR}/skills" ] && cp -r "${CLAUDE_DIR}/skills" "${backup_path}/" 2>/dev/null || true
  [ -d "${CLAUDE_DIR}/agents" ] && cp -r "${CLAUDE_DIR}/agents" "${backup_path}/" 2>/dev/null || true
  [ -f "${CLAUDE_DIR}/settings.json" ] && cp "${CLAUDE_DIR}/settings.json" "${backup_path}/" 2>/dev/null || true
  [ -f "${CLAUDE_DIR}/keybindings.json" ] && cp "${CLAUDE_DIR}/keybindings.json" "${backup_path}/" 2>/dev/null || true

  # Prune old backups (keep last 5)
  if [ -d "$BACKUP_DIR" ]; then
    local total_backups
    total_backups=$(ls -1d "${BACKUP_DIR}"/[0-9]* 2>/dev/null | wc -l)
    if [ "$total_backups" -gt 5 ]; then
    ls -1d "${BACKUP_DIR}"/[0-9]* 2>/dev/null | sort | head -n "$(( total_backups - 5 ))" | while read -r old; do
      rm -rf "$old"
    done
    fi
  fi

  log_info "Backup created: ${backup_path}"
  echo "$backup_path"
}

restore_from_backup() {
  local backup_path="$1"
  if [ ! -d "$backup_path" ]; then
    log_error "Backup not found: $backup_path"
    return 1
  fi

  log_info "Restoring from backup: $backup_path"
  [ -f "${backup_path}/CLAUDE.md" ] && cp "${backup_path}/CLAUDE.md" "${CLAUDE_DIR}/" 2>/dev/null || true
  [ -d "${backup_path}/rules" ] && cp -r "${backup_path}/rules" "${CLAUDE_DIR}/" 2>/dev/null || true
  [ -d "${backup_path}/skills" ] && cp -r "${backup_path}/skills" "${CLAUDE_DIR}/" 2>/dev/null || true
  [ -d "${backup_path}/agents" ] && cp -r "${backup_path}/agents" "${CLAUDE_DIR}/" 2>/dev/null || true
  [ -f "${backup_path}/settings.json" ] && cp "${backup_path}/settings.json" "${CLAUDE_DIR}/" 2>/dev/null || true
  [ -f "${backup_path}/keybindings.json" ] && cp "${backup_path}/keybindings.json" "${CLAUDE_DIR}/" 2>/dev/null || true
  log_info "Restore complete."
}

list_backups() {
  if [ -d "$BACKUP_DIR" ]; then
    ls -1d "${BACKUP_DIR}"/[0-9]* 2>/dev/null | sort -r
  else
    echo "No backups found."
  fi
}

# ── Sync Profiles ─────────────────────────────────────────────────────────────
resolve_profile() {
  # Resolve a profile name to its categories string
  # Usage: resolve_profile "memory-only" → "memory,claude_md"
  local profile_name="$1"

  # Check brain-config.json for user-defined profiles first
  if [ -f "$BRAIN_CONFIG" ]; then
    local user_cats
    user_cats=$(jq -r --arg p "$profile_name" '.profiles[$p].categories // empty' "$BRAIN_CONFIG" 2>/dev/null)
    if [ -n "$user_cats" ]; then
      echo "$user_cats"
      return 0
    fi
  fi

  # Fall back to defaults.json
  if [ -f "$DEFAULTS_FILE" ]; then
    local default_cats
    default_cats=$(jq -r --arg p "$profile_name" '.profiles[$p].categories // empty' "$DEFAULTS_FILE" 2>/dev/null)
    if [ -n "$default_cats" ]; then
      echo "$default_cats"
      return 0
    fi
  fi

  # Profile not found
  return 1
}

get_active_profile() {
  # Get the active profile name from brain-config.json
  if [ -f "$BRAIN_CONFIG" ]; then
    jq -r '.active_profile // "full"' "$BRAIN_CONFIG" 2>/dev/null
  else
    echo "full"
  fi
}

get_profile_categories() {
  # Get categories for the active profile (or "all" if none set)
  local profile
  profile=$(get_active_profile)
  local cats
  cats=$(resolve_profile "$profile" 2>/dev/null || echo "")
  if [ -n "$cats" ]; then
    echo "$cats"
  else
    echo "all"
  fi
}

# ── Path Encoding/Decoding ─────────────────────────────────────────────────────
# Claude Code encodes project paths: /home/user/my-project → -home-user-my--project
# Hyphens in names are doubled: my-project → my--project
# Leading slash becomes leading hyphen
decode_project_path() {
  local encoded="$1"
  # First restore leading slash, then un-double hyphens temporarily,
  # then convert remaining single hyphens to slashes, then restore hyphens
  # Uses §§ as placeholder instead of \x00 (which fails on macOS/BSD sed)
  echo "$encoded" | sed 's/^-/\//' | sed 's/--/§§/g' | sed 's/-/\//g' | sed 's/§§/-/g'
}

encode_project_path() {
  local path="$1"
  # Double any hyphens in the path first, then convert slashes to hyphens
  echo "$path" | sed 's/-/--/g' | sed 's/\//-/g'
}

# Extract a human-friendly project name from encoded path
project_name_from_encoded() {
  local encoded="$1"
  # The encoding is lossy: /foo/bar-baz → -foo-bar-baz (single hyphens for both / and -)
  # We can't perfectly reverse it, but the last segment after the final known separator
  # is usually the project name. Strategy: take everything after the last path-like prefix.
  # Common prefixes: -Users-*-Code-, -home-*-Code-, -home-*-
  local name
  # Strip common path prefixes to get the project portion
  name=$(echo "$encoded" | sed -E 's|^-Users-[^-]+-Code-||; s|^-home-[^-]+-Code-||; s|^-home-[^-]+-||; s|^-||')
  # Restore doubled hyphens to single (these are real hyphens in the name)
  name=$(echo "$name" | sed 's/--/-/g')
  # If still empty, fall back to the full encoded string
  [ -z "$name" ] && name="$encoded"
  echo "$name"
}

# ── API Call Logging & Protection ─────────────────────────────────────────────
# Centralized tracking of all claude -p API calls for debugging and cost control

BRAIN_API_LOG="${HOME}/.cache/brain-api-calls.jsonl"
BRAIN_KILL_SWITCH="${HOME}/.cache/brain-kill-switch.json"
BRAIN_CIRCUIT_BREAKER="${HOME}/.cache/brain-circuit-breaker.json"
BRAIN_API_COOLDOWN_SECONDS=300  # 5 minutes between API calls

# Log every claude -p invocation with structured data
log_api_call() {
  local caller="$1" status="$2" duration_ms="${3:-0}" budget="${4:-0}" error_msg="${5:-}"
  mkdir -p "$(dirname "$BRAIN_API_LOG")"
  local entry
  entry=$(jq -n \
    --arg ts "$(now_iso)" \
    --arg caller "$caller" \
    --arg status "$status" \
    --argjson duration "$duration_ms" \
    --arg budget "$budget" \
    --arg error "$error_msg" \
    --arg machine "$(get_machine_name 2>/dev/null || echo unknown)" \
    --arg pid "$$" \
    '{timestamp: $ts, caller: $caller, status: $status, duration_ms: $duration, budget: $budget, error: $error, machine: $machine, pid: $pid}')
  echo "$entry" >> "$BRAIN_API_LOG"

  # Prune log to last 500 entries if it gets too large
  if [ -f "$BRAIN_API_LOG" ]; then
    local line_count
    line_count=$(wc -l < "$BRAIN_API_LOG" | tr -d ' ')
    if [ "$line_count" -gt 500 ]; then
      local tmp
      tmp=$(brain_mktemp)
      tail -n 500 "$BRAIN_API_LOG" > "$tmp" && mv "$tmp" "$BRAIN_API_LOG"
    fi
  fi
}

# ── Kill Switch ───────────────────────────────────────────────────────────────
# Ultimate safety valve — blocks ALL claude -p calls when active

is_kill_switch_active() {
  if [ -f "$BRAIN_KILL_SWITCH" ]; then
    local active
    active=$(jq -r '.active // false' "$BRAIN_KILL_SWITCH" 2>/dev/null || echo "false")
    [ "$active" = "true" ]
  else
    return 1
  fi
}

activate_kill_switch() {
  local reason="${1:-manual}" triggered_by="${2:-unknown}"
  mkdir -p "$(dirname "$BRAIN_KILL_SWITCH")"
  jq -n \
    --arg ts "$(now_iso)" \
    --arg reason "$reason" \
    --arg triggered_by "$triggered_by" \
    '{active: true, activated_at: $ts, reason: $reason, triggered_by: $triggered_by}' \
    > "$BRAIN_KILL_SWITCH"
  log_warn "KILL SWITCH ACTIVATED: $reason (by $triggered_by)"
  log_api_call "kill-switch" "activated" 0 "0" "$reason"
}

deactivate_kill_switch() {
  if [ -f "$BRAIN_KILL_SWITCH" ]; then
    local tmp
    tmp=$(brain_mktemp)
    jq '.active = false | .deactivated_at = "'"$(now_iso)"'"' "$BRAIN_KILL_SWITCH" > "$tmp"
    mv "$tmp" "$BRAIN_KILL_SWITCH"
    log_info "Kill switch deactivated."
    log_api_call "kill-switch" "deactivated" 0 "0" ""
  fi
}

# ── Circuit Breaker ───────────────────────────────────────────────────────────
# Auto-trips after N consecutive failures within a time window

CIRCUIT_BREAKER_MAX_FAILURES=3
CIRCUIT_BREAKER_WINDOW_SECONDS=600  # 10 minutes

circuit_breaker_check() {
  # Returns 0 if circuit is closed (OK to call), 1 if open (blocked)
  if [ ! -f "$BRAIN_CIRCUIT_BREAKER" ]; then
    return 0
  fi

  local state
  state=$(jq -r '.state // "closed"' "$BRAIN_CIRCUIT_BREAKER" 2>/dev/null || echo "closed")

  if [ "$state" = "open" ]; then
    # Check if enough time has passed to try again (half-open)
    local tripped_at current_ts elapsed
    tripped_at=$(jq -r '.tripped_at_epoch // 0' "$BRAIN_CIRCUIT_BREAKER" 2>/dev/null || echo "0")
    current_ts=$(date +%s)
    elapsed=$(( current_ts - tripped_at ))
    if [ "$elapsed" -ge "$CIRCUIT_BREAKER_WINDOW_SECONDS" ]; then
      log_info "Circuit breaker: cooldown expired, allowing retry (half-open)."
      return 0
    fi
    log_warn "Circuit breaker OPEN — blocking API call (${elapsed}s/${CIRCUIT_BREAKER_WINDOW_SECONDS}s cooldown remaining)."
    return 1
  fi

  return 0
}

circuit_breaker_record_success() {
  mkdir -p "$(dirname "$BRAIN_CIRCUIT_BREAKER")"
  jq -n '{state: "closed", consecutive_failures: 0, last_success: "'"$(now_iso)"'"}' \
    > "$BRAIN_CIRCUIT_BREAKER"
}

circuit_breaker_record_failure() {
  local caller="${1:-unknown}"
  mkdir -p "$(dirname "$BRAIN_CIRCUIT_BREAKER")"

  local current_failures=0
  if [ -f "$BRAIN_CIRCUIT_BREAKER" ]; then
    current_failures=$(jq -r '.consecutive_failures // 0' "$BRAIN_CIRCUIT_BREAKER" 2>/dev/null || echo "0")
  fi
  current_failures=$((current_failures + 1))

  if [ "$current_failures" -ge "$CIRCUIT_BREAKER_MAX_FAILURES" ]; then
    # Trip the circuit breaker
    jq -n \
      --argjson failures "$current_failures" \
      --arg ts "$(now_iso)" \
      --argjson epoch "$(date +%s)" \
      --arg caller "$caller" \
      '{state: "open", consecutive_failures: $failures, tripped_at: $ts, tripped_at_epoch: $epoch, tripped_by: $caller}' \
      > "$BRAIN_CIRCUIT_BREAKER"
    log_warn "Circuit breaker TRIPPED after ${current_failures} consecutive failures."

    # Auto-activate kill switch if circuit breaker trips
    activate_kill_switch "Circuit breaker tripped after ${current_failures} failures" "$caller"
  else
    jq -n \
      --argjson failures "$current_failures" \
      --arg ts "$(now_iso)" \
      '{state: "closed", consecutive_failures: $failures, last_failure: $ts}' \
      > "$BRAIN_CIRCUIT_BREAKER"
    log_warn "API failure ${current_failures}/${CIRCUIT_BREAKER_MAX_FAILURES} — circuit breaker will trip at ${CIRCUIT_BREAKER_MAX_FAILURES}."
  fi
}

# ── API Cooldown ──────────────────────────────────────────────────────────────
# Prevents API calls more frequently than BRAIN_API_COOLDOWN_SECONDS

BRAIN_LAST_API_CALL_FILE="${HOME}/.cache/brain-last-api-call"

check_api_cooldown() {
  local caller="${1:-unknown}"
  if [ ! -f "$BRAIN_LAST_API_CALL_FILE" ]; then
    return 0
  fi

  local last_call_ts current_ts elapsed
  last_call_ts=$(cat "$BRAIN_LAST_API_CALL_FILE" 2>/dev/null || echo "0")
  current_ts=$(date +%s)
  elapsed=$(( current_ts - last_call_ts ))

  if [ "$elapsed" -lt "$BRAIN_API_COOLDOWN_SECONDS" ]; then
    local remaining
    remaining=$(( BRAIN_API_COOLDOWN_SECONDS - elapsed ))
    log_warn "API cooldown active — ${remaining}s remaining (caller: $caller). Skipping."
    return 1
  fi
  return 0
}

record_api_call_time() {
  mkdir -p "$(dirname "$BRAIN_LAST_API_CALL_FILE")"
  date +%s > "$BRAIN_LAST_API_CALL_FILE"
}

# ── Guarded Claude API Call ───────────────────────────────────────────────────
# Single entry point for all claude -p calls with full protection

guarded_claude_call() {
  # Usage: guarded_claude_call <caller_name> <prompt_file> <schema> <model> <budget> [extra_args...]
  # Returns: 0 on success (result in stdout), 1 on failure
  local caller="$1" prompt_file="$2" schema="$3" model="$4" budget="$5"
  shift 5

  # Gate 1: Kill switch
  if is_kill_switch_active; then
    local reason
    reason=$(jq -r '.reason // "unknown"' "$BRAIN_KILL_SWITCH" 2>/dev/null || echo "unknown")
    log_warn "KILL SWITCH ACTIVE ($reason) — blocking $caller API call."
    log_api_call "$caller" "blocked:kill-switch" 0 "$budget" "$reason"
    return 1
  fi

  # Gate 2: Circuit breaker
  if ! circuit_breaker_check; then
    log_api_call "$caller" "blocked:circuit-breaker" 0 "$budget" ""
    return 1
  fi

  # Gate 3: Cooldown
  if ! check_api_cooldown "$caller"; then
    log_api_call "$caller" "blocked:cooldown" 0 "$budget" ""
    return 1
  fi

  # All gates passed — make the call
  record_api_call_time
  local start_ts result exit_code duration_ms
  start_ts=$(date +%s)

  result=$(claude -p "$(cat "$prompt_file")" \
    --bare \
    --output-format json \
    --json-schema "$schema" \
    --model "$model" \
    --max-turns 1 \
    --max-budget-usd "$budget" \
    "$@" \
    2>/dev/null)
  exit_code=$?

  local end_ts
  end_ts=$(date +%s)
  duration_ms=$(( (end_ts - start_ts) * 1000 ))

  if [ $exit_code -eq 0 ] && [ -n "$result" ]; then
    log_api_call "$caller" "success" "$duration_ms" "$budget" ""
    circuit_breaker_record_success
    echo "$result"
    return 0
  else
    log_api_call "$caller" "failure" "$duration_ms" "$budget" "exit_code=$exit_code"
    circuit_breaker_record_failure "$caller"
    return 1
  fi
}
