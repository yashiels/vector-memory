#!/usr/bin/env bash
# vector-memory installer
# Usage: ./install.sh <project-path>
# Example: ./install.sh ~/Developer/my-app

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${REPO_DIR}/scripts"
SKILL_DIR="${HOME}/.claude/skills/vector-memory"

# ── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BLUE=''; NC=''
fi

ok()   { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${BLUE}→${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

echo ""
echo "  vector-memory installer"
echo "  ─────────────────────────────────────────"
echo ""

# ── Validate project path ───────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo "Usage: ./install.sh <project-path>"
  echo "  Example: ./install.sh ~/Developer/my-app"
  exit 1
fi

if [[ ! -d "$1" ]]; then
  fail "Project path does not exist: $1"
fi

PROJECT_PATH="$(cd "$1" && pwd)"
PROJECT_NAME="$(basename "$PROJECT_PATH" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"

info "Project: ${PROJECT_NAME} (${PROJECT_PATH})"

# ── Step 1: Check Python 3.11+ ──────────────────────────────────────────────
info "Checking Python..."
if ! command -v python3 &>/dev/null; then
  fail "Python 3 not found. Install Python 3.11+ and try again."
fi
PY_VERSION="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
PY_MAJOR="$(echo "$PY_VERSION" | cut -d. -f1)"
PY_MINOR="$(echo "$PY_VERSION" | cut -d. -f2)"
if [[ "$PY_MAJOR" -lt 3 ]] || { [[ "$PY_MAJOR" -eq 3 ]] && [[ "$PY_MINOR" -lt 11 ]]; }; then
  fail "Python ${PY_VERSION} found but 3.11+ required."
fi
ok "Python ${PY_VERSION}"

# ── Step 2: Check Docker ────────────────────────────────────────────────────
info "Checking Docker..."
if ! command -v docker &>/dev/null; then
  fail "Docker not found. Install from https://docs.docker.com/get-docker/"
fi
if ! docker info &>/dev/null 2>&1; then
  fail "Docker is installed but not running. Start Docker and try again."
fi
ok "Docker is available"

# ── Step 3: Check/install uv ────────────────────────────────────────────────
info "Checking uv..."
if ! command -v uv &>/dev/null; then
  warn "uv not found. Installing..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="${HOME}/.local/bin:${PATH}"
  if ! command -v uv &>/dev/null; then
    fail "uv install failed. Install manually: https://docs.astral.sh/uv/"
  fi
fi
ok "uv is available"

# ── Step 4: Start Qdrant ────────────────────────────────────────────────────
info "Starting Qdrant..."
if docker ps --filter "name=qdrant" --format "{{.Names}}" | grep -q "^qdrant$"; then
  ok "Qdrant is already running"
else
  mkdir -p "${HOME}/.qdrant"
  docker compose -f "${REPO_DIR}/docker/docker-compose.yml" up -d
  info "Waiting for Qdrant to be ready..."
  for _ in $(seq 1 20); do
    if curl -sf http://localhost:6333/healthz &>/dev/null; then
      break
    fi
    sleep 1
  done
  if ! curl -sf http://localhost:6333/healthz &>/dev/null; then
    fail "Qdrant did not start. Check: docker logs qdrant"
  fi
  ok "Qdrant is running at http://localhost:6333"
fi

# ── Step 5: Install Claude Code skill ───────────────────────────────────────
info "Installing vector-memory skill..."
mkdir -p "${SKILL_DIR}"
cp "${REPO_DIR}/skill/SKILL.md" "${SKILL_DIR}/SKILL.md"
ok "Skill installed at ${SKILL_DIR}/SKILL.md"

# ── Step 6: Set up Python venv for indexer ──────────────────────────────────
info "Setting up indexer dependencies..."
if [ ! -d "${SCRIPTS_DIR}/.venv" ]; then
  python3 -m venv "${SCRIPTS_DIR}/.venv"
fi
source "${SCRIPTS_DIR}/.venv/bin/activate"
pip install -q -r "${SCRIPTS_DIR}/requirements.txt"
ok "Indexer dependencies installed"

# ── Step 7: Write .mcp.json to project ──────────────────────────────────────
info "Configuring MCP server..."
UVX_PATH="$(command -v uvx)"
MCP_FILE="${PROJECT_PATH}/.mcp.json"

MCP_STATUS=$(python3 - "$MCP_FILE" "$UVX_PATH" "$PROJECT_NAME" <<'PYEOF'
import json, sys, os

mcp_file, uvx_path, project_name = sys.argv[1], sys.argv[2], sys.argv[3]

qdrant_entry = {
    "command": uvx_path,
    "args": ["--python", "3.12", "mcp-server-qdrant"],
    "env": {
        "QDRANT_URL": "http://localhost:6333",
        "COLLECTION_NAME": project_name,
        "FASTEMBED_MODEL_NAME": "sentence-transformers/all-MiniLM-L6-v2"
    }
}

if os.path.exists(mcp_file):
    with open(mcp_file) as f:
        data = json.load(f)
    if "qdrant" in data.get("mcpServers", {}):
        print("already configured")
        sys.exit(0)
    data.setdefault("mcpServers", {})["qdrant"] = qdrant_entry
    status = "added qdrant to existing .mcp.json"
else:
    data = {"mcpServers": {"qdrant": qdrant_entry}}
    status = "created .mcp.json"

with open(mcp_file, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(status)
PYEOF
)
ok ".mcp.json: ${MCP_STATUS}"

# ── Step 8: Write session-reindex hook ──────────────────────────────────────
info "Setting up session hooks..."
HOOKS_DIR="${PROJECT_PATH}/tools/vector-memory"
mkdir -p "$HOOKS_DIR"

cat > "${HOOKS_DIR}/session-reindex.sh" <<REINDEXEOF
#!/usr/bin/env bash
set -euo pipefail

VECTOR_MEMORY_WORKSPACE="\${VECTOR_MEMORY_WORKSPACE:-\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/../.." && pwd)}"
VECTOR_MEMORY_SCRIPTS="\${VECTOR_MEMORY_SCRIPTS:-${SCRIPTS_DIR}}"

export VECTOR_MEMORY_WORKSPACE
QDRANT_URL="http://localhost:6333"

if ! docker ps --filter "name=qdrant" --format "{{.Names}}" | grep -q qdrant 2>/dev/null; then
    docker start qdrant >/dev/null 2>&1 || true
    sleep 2
fi

for _ in \$(seq 1 15); do
    if curl -sf "\$QDRANT_URL/healthz" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! curl -sf "\$QDRANT_URL/healthz" >/dev/null 2>&1; then
    echo "Warning: Qdrant not reachable at \$QDRANT_URL"
    exit 0
fi

cd "\$VECTOR_MEMORY_SCRIPTS"
if [ -d ".venv" ]; then
    source .venv/bin/activate
    python3 index_codebase.py --incremental 2>&1
else
    echo "Warning: Python venv not found at \$VECTOR_MEMORY_SCRIPTS/.venv"
fi
REINDEXEOF

chmod +x "${HOOKS_DIR}/session-reindex.sh"
ok "Session reindex script at tools/vector-memory/session-reindex.sh"

# Write .claude/hooks.json (merge if exists)
CLAUDE_DIR="${PROJECT_PATH}/.claude"
HOOKS_FILE="${CLAUDE_DIR}/hooks.json"
REINDEX_CMD="${HOOKS_DIR}/session-reindex.sh"
mkdir -p "$CLAUDE_DIR"

HOOKS_STATUS=$(python3 - "$HOOKS_FILE" "$REINDEX_CMD" <<'PYEOF'
import json, sys, os

hooks_file, reindex_cmd = sys.argv[1], sys.argv[2]

if os.path.exists(hooks_file):
    with open(hooks_file) as f:
        data = json.load(f)
    hooks = data.get("hooks", {}).get("SessionStart", [])
    if any("session-reindex" in h.get("command", "") for h in hooks):
        print("already configured")
        sys.exit(0)
    data.setdefault("hooks", {}).setdefault("SessionStart", []).append({
        "type": "command",
        "command": reindex_cmd,
        "timeout": 60000
    })
    status = "added to existing hooks.json"
else:
    data = {
        "hooks": {
            "SessionStart": [{
                "type": "command",
                "command": reindex_cmd,
                "timeout": 60000
            }]
        }
    }
    status = "created hooks.json"

with open(hooks_file, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(status)
PYEOF
)
ok "hooks.json: ${HOOKS_STATUS}"

# ── Step 9: Append vector-memory block to CLAUDE.md ─────────────────────────
info "Updating CLAUDE.md..."
CLAUDE_MD="${PROJECT_PATH}/CLAUDE.md"

CLAUDE_STATUS=$(python3 - "$CLAUDE_MD" "$PROJECT_NAME" "$REPO_DIR" "$SCRIPTS_DIR" "$PROJECT_PATH" <<'PYEOF'
import sys, os

claude_md, project_name, repo_dir, scripts_dir, project_path = sys.argv[1:6]

vector_block = f"""## Vector Memory (Qdrant)

This workspace uses Qdrant vector search (`{project_name}` collection) for codebase knowledge. The indexer + skill + MCP server live in the [yashiels/vector-memory](https://github.com/yashiels/vector-memory) repo, cloned at `{repo_dir}`.

### Search Before Answering
**Always** call `qdrant-find` before using Glob, Grep, or reading large directory trees. After getting results, use `Read` on the returned file paths.

### Store After Solving
After fixing a bug, making a non-obvious decision, or discovering how something works, call `qdrant-store`:
```
[YYYY-MM-DD] <one-line summary>
Root cause: ...
Fix / decision: ...
Key files: <file:line refs>
```

### Re-indexing
The SessionStart hook (`tools/vector-memory/session-reindex.sh`) auto-runs an incremental reindex on every Claude Code session start. Manual commands:
```bash
# Incremental (only changed files)
cd {scripts_dir} && source .venv/bin/activate
VECTOR_MEMORY_WORKSPACE={project_path} python3 index_codebase.py --incremental

# Full rebuild (after large refactors)
VECTOR_MEMORY_WORKSPACE={project_path} python3 index_codebase.py --clean
```"""

if os.path.exists(claude_md):
    with open(claude_md) as f:
        content = f.read()
    if "## Vector Memory" in content:
        print("already configured")
        sys.exit(0)
    content = content.rstrip() + "\n\n" + vector_block + "\n"
    status = "appended to existing CLAUDE.md"
else:
    project_title = os.path.basename(project_path)
    content = f"# {project_title}\n\n{vector_block}\n"
    status = "created CLAUDE.md"

with open(claude_md, "w") as f:
    f.write(content)
print(status)
PYEOF
)
ok "CLAUDE.md: ${CLAUDE_STATUS}"

# ── Step 10: Run first index ────────────────────────────────────────────────
info "Running first index of ${PROJECT_NAME}..."
source "${SCRIPTS_DIR}/.venv/bin/activate"
VECTOR_MEMORY_WORKSPACE="$PROJECT_PATH" python3 "${SCRIPTS_DIR}/index_codebase.py" 2>&1
ok "First index complete"

# ── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}Setup complete!${NC}"
echo ""
echo "  Project:    ${PROJECT_NAME}"
echo "  Collection: ${PROJECT_NAME}"
echo "  MCP:        ${MCP_FILE}"
echo "  Hooks:      ${HOOKS_FILE}"
echo "  CLAUDE.md:  ${CLAUDE_MD}"
echo ""
echo "  Restart Claude Code and start asking questions about your codebase."
echo ""
