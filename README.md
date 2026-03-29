<p align="center">
  <h1 align="center">claude-brain (fork)</h1>
  <p align="center">
    <strong>Sync your Claude Code brain across machines and surfaces — CLI, Desktop, and Web.</strong>
  </p>
  <p align="center">
    <b>claude-brain</b> is a Claude Code plugin for <b>brain sync</b> — sync Claude Code memory, skills, agents, rules, and settings across all your machines with semantic merge. This fork adds bug fixes, new commands, sync profiles, and an MCP server for Claude Desktop and Web access.
  </p>
  <p align="center">
    <a href="https://github.com/johnkattenhorn/claude-brain/stargazers"><img src="https://img.shields.io/github/stars/johnkattenhorn/claude-brain?style=social" alt="Stars"></a>
    <a href="https://github.com/johnkattenhorn/claude-brain/blob/main/LICENSE"><img src="https://img.shields.io/github/license/johnkattenhorn/claude-brain" alt="License"></a>
    <img src="https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20WSL-blue" alt="Platform">
    <img src="https://img.shields.io/badge/Claude%20Code-Plugin-blueviolet" alt="Claude Code Plugin">
    <a href="https://github.com/johnkattenhorn/claude-brain/actions"><img src="https://github.com/johnkattenhorn/claude-brain/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  </p>
</p>

> **Fork of [toroleapinc/claude-brain](https://github.com/toroleapinc/claude-brain)** by [Eddie Liang](https://github.com/toroleapinc). Original concept, architecture, and core implementation by the upstream project. This fork builds on that foundation with bug fixes, new features, and cross-surface support. See [What's Different](#whats-different-in-this-fork) below.

---

## The Problem

You use Claude Code on multiple machines. Your laptop has learned your coding patterns. Your desktop has custom skills. Your cloud VM has different rules. **None of them talk to each other.**

Every time you switch machines, you lose context. You re-teach Claude the same things. Your carefully crafted CLAUDE.md stays behind.

And if you use Claude on the web or desktop app, none of your accumulated knowledge follows you there either.

## The Solution

```
# Machine A (work laptop)
> /brain-init git@github.com:you/my-brain.git
  Brain exported: 42 memory entries, 3 skills, 5 rules
  Pushed to remote

# Machine B (home desktop)
> /brain-join git@github.com:you/my-brain.git
  Pulled brain: 42 memory entries, 3 skills, 5 rules
  Merged with local state
  Auto-sync enabled

# That's it. Every session start/end syncs automatically.
# Your brain follows you — including to Claude Web and Desktop via MCP.
```

## What's Different in This Fork

This fork fixes critical bugs in the upstream plugin and adds new capabilities:

### Bug Fixes (v0.2.0)
- **Plugin skills not loading** — upstream `plugin.json` was missing the `skills` array
- **Keybindings merge crash** — invalid jq `unique_by` syntax
- **Settings merge env var leak** — remote env/mcpServers could bleed through
- **Semantic merge fallback** — memory from non-base machines was silently dropped
- **Auto-evolve was a no-op** — only updated timestamp, never applied promotions
- **macOS sed incompatibility** — GNU `\L` syntax fails on BSD sed
- **Project name decoder** — returned empty strings for hyphenated project names

### New Features (v0.3.0+)
- **Status line HUD** — persistent brain status in Claude Code (sync time, conflicts, dirty state)
- **`/brain-diff`** — preview what would change before syncing
- **`/brain-doctor`** — comprehensive health check for your brain setup
- **`/brain-profile`** — sync profiles to control what syncs per-machine
- **`--dry-run`** on `/brain-sync` — preview mode for push and pull
- **`/brain-log [count]`** — filter sync history with count or `--all`
- **Selective sync** — `--categories memory,claude_md,rules` on export/import
- **Delta sync** — skips re-export when no local files have changed
- **Configurable merge model** — set `merge_model` in `defaults.json` (not hardcoded)
- **GitHub Actions CI** — shellcheck + test suite on every push/PR

### MCP Server for Desktop and Web (v0.5.0)
- **Brain MCP server** — self-hosted server that exposes brain data to Claude Desktop and claude.ai
- Read your CLAUDE.md, memory, rules, skills, machines, and sync history
- Search memory across all projects
- Refresh from git to pick up latest syncs
- Inspect per-machine snapshots
- Runs locally (stdio) or remotely (HTTP/SSE behind Traefik)
- Docker deployment with health checks

## Quick Start

### Install the Plugin

In a Claude Code session, run these commands one at a time:

```
/plugin marketplace add johnkattenhorn/claude-brain
```

Then:

```
/plugin install claude-brain-sync
```

Then **restart Claude Code**. Note: `/reload-plugins` alone is not sufficient for newly installed plugins.

### Initialize (first machine)

```
/brain-init git@github.com:you/my-brain.git
```

### Join (other machines)

```
/brain-join git@github.com:you/my-brain.git
```

### With encryption

```
/brain-init git@github.com:you/my-brain.git --encrypt
```

Done. Auto-sync handles everything from here.

## Commands

| Command | Description |
|---------|-------------|
| `/brain-init <remote>` | Initialize brain network with a Git remote |
| `/brain-join <remote>` | Join an existing brain network |
| `/brain-status` | Show brain inventory and sync status |
| `/brain-sync [--dry-run]` | Manually trigger full sync cycle (or preview) |
| `/brain-diff` | Preview what would change on next sync |
| `/brain-doctor` | Health check — config, repo, snapshots, deps |
| `/brain-profile [list\|set\|create\|delete]` | Manage sync profiles |
| `/brain-evolve` | Promote stable patterns from memory to config |
| `/brain-conflicts` | Review and resolve merge conflicts |
| `/brain-share <type> <name>` | Share a skill, agent, or rule with the team |
| `/brain-shared-list` | List all shared artifacts in the network |
| `/brain-log [count]` | Show sync history (default 20, or specify count) |

## Sync Profiles

Control what syncs per-machine. Built-in profiles:

| Profile | Categories | Use case |
|---------|-----------|----------|
| `full` | Everything (default) | Personal machines you fully control |
| `memory-only` | memory, claude_md | Shared/corporate machines — knowledge only |
| `knowledge` | memory, claude_md, rules, skills, agents | Skip settings/environmental config |

```
/brain-profile list            # see all profiles
/brain-profile set memory-only # switch active profile
/brain-profile create work memory,claude_md,rules  # custom profile
```

## What Gets Synced

| Component | Synced? | Merge Strategy |
|-----------|---------|----------------|
| CLAUDE.md | Yes | Semantic merge |
| Rules | Yes | Union by filename |
| Skills | Yes | Union by name |
| Agents | Yes | Union by name |
| Auto memory | Yes | Semantic merge |
| Agent memory | Yes | Semantic merge |
| Settings (hooks, permissions) | Yes | Deep merge (local env preserved) |
| Keybindings | Yes | Union |
| MCP servers | Yes | Union (env vars stripped) |
| Shared team artifacts | Yes | Union via shared namespace |
| **OAuth tokens** | **Never** | Security |
| **Env vars** | **Never** | Machine-specific |
| **API keys** | **Never** | Stripped automatically |

## Architecture

```
Machine A              Machine B              Machine C
+-----------+          +-----------+          +-----------+
| claude-   |          | claude-   |          | claude-   |
| brain     |          | brain     |          | brain     |
| plugin    |          | plugin    |          | plugin    |
+-----+-----+          +-----+-----+          +-----+-----+
      |                      |                      |
      +----------+-----------+----------+-----------+
                 |     Git Remote       |
                 |  (your private       |
                 |       repo)          |
                 +-----------+----------+
                             |
                    Brain MCP Server
                    (self-hosted, optional)
                       /         \
                Claude Desktop  claude.ai
                (MCP client)   (MCP client)
```

**Claude Code** uses the native plugin (direct file I/O, hooks, slash commands).
**Desktop and Web** connect via the MCP server (read-only brain access + search).
The MCP server is never registered in Claude Code's config to avoid tool duplication.

**Merge strategy:**
- **Structured data** (settings, keybindings, MCP) -> deterministic JSON deep-merge (free)
- **Unstructured data** (memory, CLAUDE.md) -> LLM-powered semantic merge via `claude -p` (~$0.01-0.05)

## MCP Server (Desktop and Web)

The Brain MCP server gives Claude Desktop and claude.ai read access to your brain data. See [mcp-server/README.md](mcp-server/README.md) for full setup.

### Quick local setup (Claude Desktop)

```bash
cd mcp-server
pip install -r requirements.txt
python server.py  # stdio mode
```

### Remote setup (Docker, for Desktop + Web)

```bash
cd mcp-server
docker compose up -d
```

### Available MCP resources and tools

**Resources (read-only):**

| URI | Description |
|-----|-------------|
| `brain://claude-md` | CLAUDE.md content |
| `brain://status` | Sync status and machine info |
| `brain://memory` | Memory index by project |
| `brain://memory/{project}/{entry}` | Specific memory entry |
| `brain://rules` | All rules |
| `brain://skills` | Skill names |
| `brain://agents` | Agent names |
| `brain://machines` | Network machine list |
| `brain://log` | Recent sync history |

**Tools (actions):**

| Tool | Description |
|------|-------------|
| `search_memory(query, limit)` | Full-text search across all memory |
| `refresh_brain()` | Git pull to get latest synced data |
| `get_machine_snapshot(machine_id)` | Inspect a machine's state (use hex ID) |

## Security

claude-brain is designed with security as a first-class concern:

- **Secrets are never exported** — OAuth tokens, API keys, env vars, `.claude.json` are all excluded
- **Pattern-based secret scanning** — warns if potential secrets are detected in memory
- **MCP env vars stripped** — server configs sync without credentials
- **Settings merge is safe** — remote env/mcpServers are stripped before merge (fixed in this fork)
- **Private repo enforced** — warns if public repo detected
- **Automatic backups** — every import creates a backup in `~/.claude/brain-backups/`
- **Machine trust model** — only add machines you fully control
- **Optional encryption** — `age` encryption for snapshots at rest
- **MCP server isolation** — not registered in Claude Code config, only Desktop/Web

### What IS exported
- CLAUDE.md, rules, skills, agents
- Auto memory and agent memory
- Settings (hooks, permissions — NOT env vars)
- MCP server configurations (env vars stripped)
- Keybindings
- Machine hostname and project directory names

### What is NEVER exported
- OAuth tokens and API keys
- `~/.claude.json` (credentials)
- Environment variables from settings
- MCP server `env` fields
- `.local` config files
- Session transcripts

## API Costs

| Operation | Cost | When |
|-----------|------|------|
| Structured merge | **Free** | Every sync |
| Semantic merge | ~$0.01-0.05 | Only when content differs |
| Auto-evolve | ~$0.02-0.10 | At most once per 7 days |
| Export / import | **Free** | Every sync |

**Typical monthly cost: $0.50-2.00** for active multi-machine use. Budget cap: $0.50/call (configurable via `defaults.json`).

## Platform Support

| Platform | Status |
|----------|--------|
| Linux | Fully supported |
| macOS | Fully supported (Apple Silicon + Intel) |
| WSL | Fully supported (WSL2 recommended) |
| Windows native | Not supported (use WSL) |
| Claude Desktop | Via MCP server |
| Claude Web (claude.ai) | Via MCP server |

## Dependencies

- `git` — sync transport
- `jq` — JSON processing (`apt install jq` / `brew install jq`)
- `claude` CLI — semantic merge (already installed with Claude Code)
- `age` — optional, for encryption
- `python3` + `fastmcp` — optional, for MCP server

## Configuration

Edit `config/defaults.json` to customise:

```json
{
  "merge_model": "sonnet",          // Model for semantic merge
  "max_budget_usd": 0.50,           // Budget cap per LLM call
  "merge_confidence_threshold": 0.8, // Auto-resolve above this
  "evolve_interval_days": 7,         // Auto-evolve frequency
  "profiles": {                      // Sync profiles
    "full": { "categories": "all" },
    "memory-only": { "categories": "memory,claude_md" }
  }
}
```

## Credits

This is a fork of [toroleapinc/claude-brain](https://github.com/toroleapinc/claude-brain), created by [Eddie Liang / edvatar](https://github.com/toroleapinc). The original project designed the architecture, merge model, brain snapshot format, and core sync workflow. This fork fixes bugs, adds features, and extends the concept to work across Claude surfaces.

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT — see [LICENSE](LICENSE) for details.
