# claude-brain-sync Fork Roadmap

Fork of [toroleapinc/claude-brain](https://github.com/toroleapinc/claude-brain) by [johnkattenhorn](https://github.com/johnkattenhorn).

## v0.2.0 — Critical Fixes

Issues inherited from upstream that must be fixed before reliable use.

### Bug Fixes

- [x] **plugin.json missing skills/agents/hooks arrays** — skills don't load without explicit listing (#24 upstream)
- [ ] **import.sh keybindings merge crash** — `unique_by(.key, .command)` is invalid jq; should be `unique_by({key, command})`
- [ ] **import.sh settings merge leaks env vars** — `$local * $remote` overwrites local before env/mcpServers patch
- [ ] **merge-semantic.sh fallback broken** — concatenation overwrites output instead of appending
- [ ] **evolve.sh auto-apply is a no-op** — claims to apply promotions but only updates timestamp
- [ ] **Hardcoded `--model sonnet`** in merge-semantic.sh — should be configurable via defaults.json
- [ ] **macOS sed compatibility** — GNU `\L` syntax fails silently on BSD sed

### Infrastructure

- [ ] **Add GitHub Actions CI** — shellcheck + test suite on push/PR
- [ ] **Add shellcheck linting** for all .sh files
- [ ] **Expand test coverage** to ~70% (semantic merge, pull/push flow, error scenarios)

## v0.3.0 — Status HUD & UX

### Status Line HUD

Persistent status indicator in Claude Code showing brain state at a glance.

- [ ] **Status line hook** — update Claude Code status line after each sync with:
  - Last sync time (e.g. "Brain: synced 2m ago")
  - Conflict count (e.g. "Brain: 3 conflicts")
  - Dirty state (e.g. "Brain: unsaved changes")
  - Network machine count
- [ ] **Color coding** — green (clean), yellow (dirty/conflicts), red (sync failed)

### New Commands

- [ ] **`/brain-diff`** — preview what would change before sync (dry-run with diff output)
- [ ] **`/brain-doctor`** — health check: detect corruption, stale conflicts, orphaned snapshots, config issues
- [ ] **`/brain-log --last N`** — filter log to recent entries
- [ ] **`--dry-run` flag** on `/brain-sync`, `/brain-push`, `/brain-pull`

### Error Handling

- [ ] **Surface hook failures** to user (not silent)
- [ ] **JSON schema validation** for config files and snapshots
- [ ] **Graceful degradation** when network is down (queue pushes for retry)

## v0.4.0 — Selective Sync & Profiles

- [ ] **Selective sync** — choose which categories to sync per-machine (e.g. only memory, skip skills)
- [ ] **Sync profiles** — named configurations for different contexts (work, personal, shared-team)
- [ ] **Configurable merge model** — choose which Claude model for semantic merge
- [ ] **Bandwidth optimization** — delta sync instead of full snapshots

## v0.5.0 — Claude Desktop & Web Sync

Extend brain sync beyond Claude Code CLI.

### Brain MCP Server (self-hosted)

Single MCP server that serves brain data to both Desktop and Web. Hosted on homelab infrastructure
(not in `~/.claude.json`) to avoid Claude Code picking it up — CLI uses the native plugin as designed.

- [ ] **Brain MCP server** — lightweight server that reads from brain git repo, exposes:
  - `brain://claude-md` — current CLAUDE.md content
  - `brain://memory` — memory entries (searchable)
  - `brain://rules` — active rules
  - `brain://skills` — skill catalog
  - `brain://status` — sync state, last update, machine list
- [ ] **Write-back support** — MCP tools for Desktop/Web to push changes back to brain repo
- [ ] **Homelab deployment** — Docker container on homelab, Traefik reverse proxy, accessible via LAN/VPN
- [ ] **Auto-refresh** — watch brain repo for changes, serve latest state

### Client Configuration

- **Claude Code** — uses native plugin (no MCP needed, no config change)
- **Claude Desktop** — add MCP server URL in Desktop settings only
- **Claude Web** — connect via claude.ai MCP integration

### Architecture

```
                    Git Remote (OneDev/GitHub)
                           |
                     Brain Git Repo
                      /          \
                     /            \
           Claude Code         Brain MCP Server
           (native plugin)     (self-hosted, homelab)
           direct file I/O        |         |
                            Desktop App  claude.ai
                            (MCP client) (MCP client)
```

**Key design constraint:** The MCP server is never registered in `~/.claude.json` or
Claude Code's MCP config. This prevents Claude Code from using it (it has the plugin)
and avoids the duplicate-tool / conflicting-behavior problem.

## v1.0.0 — Production Ready

- [ ] **Full CI/CD** — automated testing, linting, release, marketplace publishing
- [ ] **Comprehensive test suite** — 90%+ coverage
- [ ] **Audit log** — track all changes with who/when/what
- [ ] **Race condition fixes** — atomic JSON operations, file locking
- [ ] **Large brain support** — chunked export/import, streaming merge
- [ ] **Team features** — per-artifact permissions, approval workflow for shared items
- [ ] **Documentation** — troubleshooting guide, FAQ, tutorials

## Design Decisions

### Why fork?

The upstream plugin has good architecture but several critical bugs, no CI/CD, and incomplete features (auto-evolve). This fork aims to make it production-ready and extend it to work across all Claude surfaces (CLI, Desktop, Web).

### Status Line approach

Claude Code supports status line configuration. Rather than polling, we update the status line as a side-effect of sync hooks — zero overhead when not syncing.

### Desktop/Web sync via MCP (not plugin)

A single self-hosted MCP server bridges the brain repo to Desktop and Web. This is deliberately
NOT registered in Claude Code's config — CLI uses the native plugin for direct file I/O.
The MCP server is hosted on homelab infrastructure behind Traefik, accessible only via LAN/VPN.
This avoids the problem where Claude Code picks up MCP servers meant for other clients and
creates duplicate/conflicting tool behavior.
