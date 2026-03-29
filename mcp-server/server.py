#!/usr/bin/env python3
"""Brain Sync MCP Server — Exposes brain data to Claude Desktop and Claude Web.

Reads from the brain git repo (consolidated brain + machine snapshots).
Works both locally (with live ~/.claude access) and remotely (repo-only mode).

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
CONSOLIDATED = BRAIN_REPO / "consolidated" / "brain.json"

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


def get_brain() -> dict:
    """Load the consolidated brain JSON. This is the primary data source."""
    return read_json(CONSOLIDATED)


def git_pull_repo():
    """Pull latest changes from the brain repo."""
    try:
        subprocess.run(
            ["git", "-C", str(BRAIN_REPO), "pull", "origin", "main"],
            capture_output=True, text=True, timeout=15,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass


# ── Resources (read-only brain data) ────────────────────────────────────────

@mcp.resource("brain://claude-md")
def get_claude_md() -> str:
    """Current CLAUDE.md content — your global instructions for Claude."""
    brain = get_brain()
    content = brain.get("declarative", {}).get("claude_md", {}).get("content", "")
    return content if content else "No CLAUDE.md found in consolidated brain."


@mcp.resource("brain://status")
def get_status() -> str:
    """Brain sync status: machines, last export times, snapshot info."""
    machines = read_json(BRAIN_REPO / "meta" / "machines.json")
    brain = get_brain()

    # Collect per-machine status from snapshots
    machine_statuses = []
    machines_dir = BRAIN_REPO / "machines"
    if machines_dir.is_dir():
        for snap_dir in sorted(machines_dir.iterdir()):
            snap_file = snap_dir / "brain-snapshot.json"
            if snap_file.exists():
                snap = read_json(snap_file)
                machine_statuses.append({
                    "id": snap.get("machine", {}).get("id", snap_dir.name),
                    "name": snap.get("machine", {}).get("name", "unknown"),
                    "os": snap.get("machine", {}).get("os", "unknown"),
                    "exported_at": snap.get("exported_at", "unknown"),
                })

    status = {
        "machines_in_network": len(machines.get("machines", [])),
        "machine_snapshots": machine_statuses,
        "consolidated_brain_exists": CONSOLIDATED.is_file(),
        "brain_schema": brain.get("schema_version", "unknown"),
    }
    return json.dumps(status, indent=2)


@mcp.resource("brain://memory")
def get_memory_index() -> str:
    """Index of all memory entries across projects (from consolidated brain)."""
    brain = get_brain()
    auto_memory = brain.get("experiential", {}).get("auto_memory", {})

    index = {}
    for project, entries in auto_memory.items():
        if isinstance(entries, dict) and entries:
            # Use "unknown-project" for empty keys (caused by encoding bug)
            key = project if project else "unknown-project"
            index[key] = list(entries.keys())

    return json.dumps(index, indent=2) if index else "No memory entries in consolidated brain."


@mcp.resource("brain://memory/{project}/{entry}")
def get_memory_entry(project: str, entry: str) -> str:
    """Read a specific memory entry by project and filename."""
    brain = get_brain()
    auto_memory = brain.get("experiential", {}).get("auto_memory", {})

    proj_entries = auto_memory.get(project, {})
    if not proj_entries:
        return f"Project '{project}' not found. Available: {list(auto_memory.keys())}"

    entry_data = proj_entries.get(entry, {})
    if not entry_data:
        return f"Entry '{entry}' not found in '{project}'. Available: {list(proj_entries.keys())}"

    return entry_data.get("content", "No content.")


@mcp.resource("brain://rules")
def get_rules() -> str:
    """All rules from the consolidated brain."""
    brain = get_brain()
    rules = brain.get("declarative", {}).get("rules", {})
    if not rules:
        return "No rules found."
    # Return rule names and content
    result = {}
    for name, data in rules.items():
        result[name] = data.get("content", "") if isinstance(data, dict) else str(data)
    return json.dumps(result, indent=2)


@mcp.resource("brain://skills")
def get_skills() -> str:
    """All user skills from the consolidated brain."""
    brain = get_brain()
    skills = brain.get("procedural", {}).get("skills", {})
    return json.dumps(list(skills.keys()), indent=2) if skills else "No skills found."


@mcp.resource("brain://agents")
def get_agents() -> str:
    """All agents from the consolidated brain."""
    brain = get_brain()
    agents = brain.get("procedural", {}).get("agents", {})
    return json.dumps(list(agents.keys()), indent=2) if agents else "No agents found."


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
    return json.dumps(entries, indent=2) if entries else "No sync history yet."


# ── Tools (actions) ─────────────────────────────────────────────────────────

@mcp.tool()
def search_memory(query: str, limit: int = 10) -> str:
    """Search all brain memory entries for a keyword or phrase.
    Returns matching lines from memory files across all projects.
    Example: search_memory("Akka.NET") or search_memory("direct reports")"""
    brain = get_brain()
    auto_memory = brain.get("experiential", {}).get("auto_memory", {})
    results = []

    for project, entries in auto_memory.items():
        if not isinstance(entries, dict):
            continue
        project_name = project if project else "unknown-project"
        for entry_name, entry_data in entries.items():
            content = entry_data.get("content", "") if isinstance(entry_data, dict) else ""
            if query.lower() in content.lower():
                lines = content.split("\n")
                matching_lines = [l.strip() for l in lines if query.lower() in l.lower()]
                results.append({
                    "project": project_name,
                    "file": entry_name,
                    "matches": matching_lines[:3],
                })
                if len(results) >= limit:
                    break
        if len(results) >= limit:
            break

    return json.dumps({"query": query, "result_count": len(results), "results": results}, indent=2)


@mcp.tool()
def refresh_brain() -> str:
    """Pull latest brain data from the git remote.
    Call this before reading data to ensure you have the most recent sync from all machines.
    This does a 'git pull' on the brain repository."""
    try:
        result = subprocess.run(
            ["git", "-C", str(BRAIN_REPO), "pull", "origin", "main"],
            capture_output=True, text=True, timeout=15,
        )
        output = result.stdout.strip()
        if "Already up to date" in output or "Already up-to-date" in output:
            return json.dumps({"status": "ok", "message": "Already up to date."})
        return json.dumps({"status": "ok", "message": f"Updated: {output}"})
    except subprocess.TimeoutExpired:
        return json.dumps({"status": "error", "message": "Git pull timed out."})
    except FileNotFoundError:
        return json.dumps({"status": "error", "message": "Git not found."})


@mcp.tool()
def get_machine_snapshot(machine_id: str = "") -> str:
    """Get a machine's brain snapshot summary. Call with no arguments to list all machines
    and their hex IDs. Then call with a specific hex ID (e.g. '302c2345') to get details.
    IMPORTANT: Use the hex ID (like '302c2345'), not the hostname."""
    machines_dir = BRAIN_REPO / "machines"
    if not machines_dir.is_dir():
        return json.dumps({"error": "No machines directory found."})

    if not machine_id:
        # List available machines
        available = []
        for d in sorted(machines_dir.iterdir()):
            if d.is_dir() and (d / "brain-snapshot.json").exists():
                snap = read_json(d / "brain-snapshot.json")
                available.append({
                    "id": d.name,
                    "name": snap.get("machine", {}).get("name", "unknown"),
                    "exported_at": snap.get("exported_at", "unknown"),
                })
        return json.dumps({"machines": available}, indent=2)

    snap_file = machines_dir / machine_id / "brain-snapshot.json"
    if not snap_file.exists():
        return json.dumps({"error": f"No snapshot for machine '{machine_id}'."})

    snap = read_json(snap_file)
    # Return a summary, not the full snapshot (which can be huge)
    # Use (x or {}) pattern to handle None values in nested fields
    declarative = snap.get("declarative") or {}
    procedural = snap.get("procedural") or {}
    experiential = snap.get("experiential") or {}
    claude_md = declarative.get("claude_md") or {}
    summary = {
        "machine": snap.get("machine") or {},
        "exported_at": snap.get("exported_at"),
        "schema_version": snap.get("schema_version"),
        "memory_projects": list((experiential.get("auto_memory") or {}).keys()),
        "skills": list((procedural.get("skills") or {}).keys()),
        "agents": list((procedural.get("agents") or {}).keys()),
        "rules": list((declarative.get("rules") or {}).keys()),
        "has_claude_md": bool(claude_md.get("content")),
    }
    return json.dumps(summary, indent=2)


# ── Health Check Server ──────────────────────────────────────────────────────

def run_with_health(mcp_server, host: str, port: int):
    """Run MCP SSE server with a /health endpoint for Traefik."""
    import threading
    from http.server import HTTPServer, BaseHTTPRequestHandler

    health_port = port + 1

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
                    "consolidated_exists": CONSOLIDATED.is_file(),
                }
                self.wfile.write(json.dumps(status).encode())
            else:
                self.send_response(404)
                self.end_headers()

        def log_message(self, format, *args):
            pass

    health_server = HTTPServer((host, health_port), HealthHandler)
    health_thread = threading.Thread(target=health_server.serve_forever, daemon=True)
    health_thread.start()
    print(f"Health endpoint on http://{host}:{health_port}/health", file=sys.stderr)

    mcp_server.run(transport="sse", host=host, port=port)


# ── Entry Point ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    if "--http" in sys.argv:
        port = int(os.environ.get("MCP_PORT", "3008"))
        for i, arg in enumerate(sys.argv):
            if arg == "--port" and i + 1 < len(sys.argv):
                port = int(sys.argv[i + 1])
        run_with_health(mcp, host="0.0.0.0", port=port)
    else:
        mcp.run()
