# Brain MCP Server

MCP server that exposes brain sync data to Claude Desktop and Claude Web.

**Claude Code does NOT use this** — it has the native plugin. This server is exclusively for Desktop and Web clients.

## Resources (read-only)

| URI | Description |
|-----|-------------|
| `brain://claude-md` | Current CLAUDE.md content |
| `brain://status` | Sync status, machine info, conflict count |
| `brain://memory` | Index of all memory entries by project |
| `brain://memory/{project}/{entry}` | Read a specific memory entry |
| `brain://rules` | All rules |
| `brain://skills` | All user skills |
| `brain://machines` | Machines in the brain network |
| `brain://log` | Recent sync history |
| `brain://conflicts` | Unresolved merge conflicts |

## Tools (actions)

| Tool | Description |
|------|-------------|
| `search_memory(query, limit)` | Full-text search across memory |
| `trigger_sync()` | Push + pull sync cycle |
| `update_claude_md(content)` | Replace CLAUDE.md content |
| `get_brain_diff()` | Preview what would change on sync |

## Local Setup (Claude Desktop only)

```bash
cd mcp-server
pip install -r requirements.txt
python server.py  # stdio mode
```

Add to Claude Desktop config (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "brain-sync": {
      "command": "python",
      "args": ["/path/to/claude-brain-fork/mcp-server/server.py"]
    }
  }
}
```

## Remote Setup (Desktop + Web)

### Docker on homelab

```bash
cd mcp-server
docker compose up -d
```

The server runs on port 8080 with Traefik labels for `brain.khn.family`.

### Claude Desktop (remote)

Add to Desktop config:

```json
{
  "mcpServers": {
    "brain-sync": {
      "type": "sse",
      "url": "https://brain.khn.family/sse"
    }
  }
}
```

### Claude Web (claude.ai)

Settings > Connectors > Add custom connector > enter `https://brain.khn.family/sse`

## Important

Do NOT add this to `~/.claude.json` or Claude Code's MCP settings. Claude Code uses the native plugin for brain sync. Adding the MCP server would create duplicate tools and conflicting behavior.
