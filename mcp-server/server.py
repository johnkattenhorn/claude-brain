#!/usr/bin/env python3
"""Brain Sync MCP Server — Exposes brain data to Claude Desktop and Claude Web.

Reads from the brain git repo and provides resources (read) and tools (write-back).
Deploy locally (stdio) or remotely (HTTP/SSE) behind Traefik.

Usage:
  Local:   python server.py                    (stdio, for Claude Desktop)
  Remote:  python server.py --http --port 8080 (HTTP/SSE, for Desktop + Web)
"""

import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from fastmcp import FastMCP

# ── Configuration ────────────────────────────────────────────────────────────

BRAIN_REPO = Path(os.environ.get("BRAIN_REPO", Path.home() / ".claude" / "brain-repo"))
CLAUDE_DIR = Path(os.environ.get("CLAUDE_DIR", Path.home() / ".claude"))
BRAIN_CONFIG = CLAUDE_DIR / "brain-config.json"

mcp = FastMCP("brain-sync")


# ── Helpers ──────────────────────────────────────────────────────────────────

def read_json(path: Path) -> dict:
    """Safely read a JSON file, return empty dict on failure."""
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def read_text(path: Path) -> str:
    """Safely read a text file, return empty string on failure."""
    try:
        return path.read_text()
    except FileNotFoundError:
        return ""


def scan_markdown_dir(directory: Path) -> dict[str, str]:
    """Scan a directory for .md files, return {filename: content}."""
    result = {}
    if directory.is_dir():
        for f in sorted(directory.rglob("*.md")):
            key = str(f.relative_to(directory))
            result[key] = f.read_text()
    return result


# ── Resources (read-only brain data) ────────────────────────────────────────

@mcp.resource("brain://claude-md")
def get_claude_md() -> str:
    """Current CLAUDE.md content — your global instructions for Claude."""
    content = read_text(CLAUDE_DIR / "CLAUDE.md")
    return content if content else "No CLAUDE.md found."


@mcp.resource("brain://status")
def get_status() -> str:
    """Brain sync status: last sync times, dirty flag, machine info."""
    config = read_json(BRAIN_CONFIG)
    machines = read_json(BRAIN_REPO / "meta" / "machines.json")

    # Count conflicts
    conflicts_file = CLAUDE_DIR / "brain-conflicts.json"
    conflicts = read_json(conflicts_file)
    conflict_count = len(conflicts.get("conflicts", []))

    status = {
        "machine_id": config.get("machine_id", "unknown"),
        "machine_name": config.get("machine_name", "unknown"),
        "last_push": config.get("last_push", "never"),
        "last_pull": config.get("last_pull", "never"),
        "dirty": config.get("dirty", False),
        "active_profile": config.get("active_profile", "full"),
        "conflict_count": conflict_count,
        "machines_in_network": len(machines.get("machines", [])),
        "remote": config.get("remote", "not configured"),
    }
    return json.dumps(status, indent=2)


@mcp.resource("brain://memory")
def get_memory_index() -> str:
    """Index of all memory entries across projects."""
    projects_dir = CLAUDE_DIR / "projects"
    index = {}

    if projects_dir.is_dir():
        for proj_dir in sorted(projects_dir.iterdir()):
            if not proj_dir.is_dir():
                continue
            mem_dir = proj_dir / "memory"
            if mem_dir.is_dir():
                entries = scan_markdown_dir(mem_dir)
                if entries:
                    # Decode project name from encoded path
                    encoded = proj_dir.name
                    project_name = encoded.replace("--", "\x00").lstrip("-").replace("-", "/").replace("\x00", "-")
                    project_name = Path(project_name).name
                    index[project_name] = list(entries.keys())

    return json.dumps(index, indent=2)


@mcp.resource("brain://memory/{project}/{entry}")
def get_memory_entry(project: str, entry: str) -> str:
    """Read a specific memory entry by project and filename."""
    projects_dir = CLAUDE_DIR / "projects"
    if not projects_dir.is_dir():
        return "No projects directory found."

    for proj_dir in projects_dir.iterdir():
        if not proj_dir.is_dir():
            continue
        decoded = proj_dir.name.replace("--", "\x00").lstrip("-").replace("-", "/").replace("\x00", "-")
        if Path(decoded).name == project:
            mem_file = proj_dir / "memory" / entry
            if mem_file.exists():
                return mem_file.read_text()
            return f"Memory entry '{entry}' not found in project '{project}'."

    return f"Project '{project}' not found."


@mcp.resource("brain://rules")
def get_rules() -> str:
    """All rules from ~/.claude/rules/."""
    rules = scan_markdown_dir(CLAUDE_DIR / "rules")
    return json.dumps(rules, indent=2) if rules else "No rules found."


@mcp.resource("brain://skills")
def get_skills() -> str:
    """All user skills from ~/.claude/skills/."""
    skills = scan_markdown_dir(CLAUDE_DIR / "skills")
    return json.dumps(list(skills.keys()), indent=2) if skills else "No skills found."


@mcp.resource("brain://machines")
def get_machines() -> str:
    """All machines in the brain network."""
    machines = read_json(BRAIN_REPO / "meta" / "machines.json")
    return json.dumps(machines.get("machines", []), indent=2)


@mcp.resource("brain://log")
def get_sync_log() -> str:
    """Recent sync history (last 20 entries)."""
    log = read_json(BRAIN_REPO / "meta" / "merge-log.json")
    entries = log.get("entries", [])[:20]
    return json.dumps(entries, indent=2)


@mcp.resource("brain://conflicts")
def get_conflicts() -> str:
    """Unresolved merge conflicts."""
    conflicts = read_json(CLAUDE_DIR / "brain-conflicts.json")
    items = conflicts.get("conflicts", [])
    if not items:
        return "No unresolved conflicts."
    return json.dumps(items, indent=2)


# ── Tools (actions) ─────────────────────────────────────────────────────────

@mcp.tool()
def search_memory(query: str, limit: int = 10) -> str:
    """Search all memory entries for a keyword or phrase."""
    results = []
    projects_dir = CLAUDE_DIR / "projects"

    if not projects_dir.is_dir():
        return json.dumps({"results": [], "message": "No projects directory found."})

    for proj_dir in projects_dir.iterdir():
        if not proj_dir.is_dir():
            continue
        mem_dir = proj_dir / "memory"
        if not mem_dir.is_dir():
            continue

        decoded = proj_dir.name.replace("--", "\x00").lstrip("-").replace("-", "/").replace("\x00", "-")
        project_name = Path(decoded).name

        for mem_file in mem_dir.rglob("*.md"):
            content = mem_file.read_text()
            if query.lower() in content.lower():
                # Extract matching context
                lines = content.split("\n")
                matching_lines = [l.strip() for l in lines if query.lower() in l.lower()]
                results.append({
                    "project": project_name,
                    "file": mem_file.name,
                    "matches": matching_lines[:3],
                })
                if len(results) >= limit:
                    break
        if len(results) >= limit:
            break

    return json.dumps({"query": query, "result_count": len(results), "results": results}, indent=2)


@mcp.tool()
def trigger_sync() -> str:
    """Trigger a brain push+pull sync cycle."""
    plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")

    if not plugin_root:
        # Try to find plugin
        for candidate in [
            CLAUDE_DIR / "plugins" / "cache" / "claude-brain-sync",
            CLAUDE_DIR / "plugins" / "claude-brain",
        ]:
            if candidate.is_dir():
                # Find the scripts dir
                for scripts_dir in candidate.rglob("scripts/push.sh"):
                    plugin_root = str(scripts_dir.parent.parent)
                    break
            if plugin_root:
                break

    if not plugin_root:
        return json.dumps({"error": "Could not find brain plugin. Set CLAUDE_PLUGIN_ROOT."})

    results = {}

    # Push
    try:
        push_result = subprocess.run(
            ["bash", f"{plugin_root}/scripts/push.sh", "--quiet", "--skip-secret-scan"],
            capture_output=True, text=True, timeout=30,
        )
        results["push"] = {"status": "ok" if push_result.returncode == 0 else "error",
                           "output": push_result.stderr.strip()}
    except subprocess.TimeoutExpired:
        results["push"] = {"status": "timeout"}

    # Pull
    try:
        pull_result = subprocess.run(
            ["bash", f"{plugin_root}/scripts/pull.sh", "--quiet", "--auto-merge"],
            capture_output=True, text=True, timeout=30,
        )
        results["pull"] = {"status": "ok" if pull_result.returncode == 0 else "error",
                           "output": pull_result.stderr.strip()}
    except subprocess.TimeoutExpired:
        results["pull"] = {"status": "timeout"}

    return json.dumps(results, indent=2)


@mcp.tool()
def update_claude_md(content: str) -> str:
    """Replace CLAUDE.md content entirely. Use with care."""
    path = CLAUDE_DIR / "CLAUDE.md"

    # Backup current
    if path.exists():
        backup = CLAUDE_DIR / "CLAUDE.md.bak"
        backup.write_text(path.read_text())

    path.write_text(content)
    return json.dumps({"status": "ok", "message": "CLAUDE.md updated. Run sync to propagate."})


@mcp.tool()
def get_brain_diff() -> str:
    """Show what would change on next sync (like /brain-diff)."""
    plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")

    if not plugin_root:
        return json.dumps({"error": "CLAUDE_PLUGIN_ROOT not set."})

    try:
        result = subprocess.run(
            ["bash", f"{plugin_root}/scripts/push.sh", "--dry-run"],
            capture_output=True, text=True, timeout=15,
        )
        push_diff = result.stderr.strip() + "\n" + result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        push_diff = "Could not compute push diff."

    try:
        result = subprocess.run(
            ["bash", f"{plugin_root}/scripts/pull.sh", "--dry-run"],
            capture_output=True, text=True, timeout=15,
        )
        pull_diff = result.stderr.strip() + "\n" + result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pull_diff = "Could not compute pull diff."

    return json.dumps({"push_diff": push_diff, "pull_diff": pull_diff}, indent=2)


# ── Health Check Server ──────────────────────────────────────────────────────

def run_with_health(mcp_server, host: str, port: int):
    """Run MCP SSE server with a /health endpoint for Traefik."""
    import threading
    from http.server import HTTPServer, BaseHTTPRequestHandler

    health_port = port + 1  # Health on port+1 (e.g., 3009 if MCP on 3008)

    class HealthHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/health":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                status = {
                    "status": "ok",
                    "service": "brain-mcp",
                    "brain_repo_exists": BRAIN_REPO.is_dir(),
                    "config_exists": BRAIN_CONFIG.is_file(),
                }
                self.wfile.write(json.dumps(status).encode())
            else:
                self.send_response(404)
                self.end_headers()

        def log_message(self, format, *args):
            pass  # Suppress access logs

    health_server = HTTPServer((host, health_port), HealthHandler)
    health_thread = threading.Thread(target=health_server.serve_forever, daemon=True)
    health_thread.start()
    print(f"Health endpoint on http://{host}:{health_port}/health", file=sys.stderr)

    # Run MCP server on main thread
    mcp_server.run(transport="sse", host=host, port=port)


# ── Entry Point ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    if "--http" in sys.argv:
        # Remote HTTP/SSE mode
        port = int(os.environ.get("MCP_PORT", "3008"))
        for i, arg in enumerate(sys.argv):
            if arg == "--port" and i + 1 < len(sys.argv):
                port = int(sys.argv[i + 1])
        run_with_health(mcp, host="0.0.0.0", port=port)
    else:
        # Local stdio mode (default)
        mcp.run()
