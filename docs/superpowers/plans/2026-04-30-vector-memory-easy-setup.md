# Vector Memory Easy Setup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make vector-memory a one-command setup for any project — `./install.sh /path/to/project` handles everything (Docker, Python, MCP, skill, hooks, first index) with zero manual file editing.

**Architecture:** Replace the current "install globally, then copy templates manually" flow with a single `install.sh <project-path>` that auto-detects the project name, writes `.mcp.json`, injects CLAUDE.md instructions, sets up session hooks, and runs the first index. The skill (`SKILL.md`) is refined to be tighter and more prescriptive about when to search vs store.

**Tech Stack:** Bash (installer), Python 3.11+ (indexer), Docker (Qdrant), MCP protocol (qdrant-find/qdrant-store)

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `install.sh` | Rewrite | One-command installer: `./install.sh <project-path>` — Docker, venv, MCP, skill, hooks, CLAUDE.md, first index |
| `uninstall.sh` | Create | Clean removal: remove MCP entry, hooks, CLAUDE.md block (does NOT delete Qdrant data or skill) |
| `skill/SKILL.md` | Rewrite | Tighter skill: clearer trigger rules, better store format, no redundant sections, no hardcoded paths |
| `templates/` | Delete (entire dir) | No longer needed — installer writes all project files directly |
| `README.md` | Rewrite | Simplified: clone, run one command, done |

---

### Task 1: Rewrite `install.sh` — Accept Project Path Argument

**Files:**
- Modify: `install.sh`

The current installer requires 6 manual steps after running. The new installer takes a project path argument and does everything automatically. Key improvements over v1 plan: Python version check, portable sed (no macOS-only `sed -i ''`), safe Python argument passing via `sys.argv` instead of shell interpolation.

- [ ] **Step 1: Write the new install.sh**

Replace `install.sh` with:

```bash
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
  for i in $(seq 1 20); do
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

python3 - "$MCP_FILE" "$UVX_PATH" "$PROJECT_NAME" <<'PYEOF'
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
        print("EXISTS")
        sys.exit(0)
    data.setdefault("mcpServers", {})["qdrant"] = qdrant_entry
    print("MERGED")
else:
    data = {"mcpServers": {"qdrant": qdrant_entry}}
    print("CREATED")

with open(mcp_file, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF

MCP_RESULT=$(python3 - "$MCP_FILE" "$UVX_PATH" "$PROJECT_NAME" <<'PYEOF2'
import json, sys, os
mcp_file = sys.argv[1]
if os.path.exists(mcp_file):
    with open(mcp_file) as f:
        data = json.load(f)
    if "qdrant" in data.get("mcpServers", {}):
        print("EXISTS")
    else:
        print("MISSING")
else:
    print("MISSING")
PYEOF2
)
if [[ "$MCP_RESULT" == "EXISTS" ]]; then
  ok ".mcp.json configured"
else
  warn ".mcp.json may need manual review"
fi

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

for i in \$(seq 1 15); do
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
ok "Session reindex script created at tools/vector-memory/session-reindex.sh"

# Write .claude/hooks.json (merge if exists)
CLAUDE_DIR="${PROJECT_PATH}/.claude"
HOOKS_FILE="${CLAUDE_DIR}/hooks.json"
REINDEX_CMD="${HOOKS_DIR}/session-reindex.sh"
mkdir -p "$CLAUDE_DIR"

python3 - "$HOOKS_FILE" "$REINDEX_CMD" <<'PYEOF3'
import json, sys, os

hooks_file, reindex_cmd = sys.argv[1], sys.argv[2]

if os.path.exists(hooks_file):
    with open(hooks_file) as f:
        data = json.load(f)
    hooks = data.get("hooks", {}).get("SessionStart", [])
    if any("session-reindex" in h.get("command", "") for h in hooks):
        print("EXISTS")
        sys.exit(0)
    data.setdefault("hooks", {}).setdefault("SessionStart", []).append({
        "type": "command",
        "command": reindex_cmd,
        "timeout": 60000
    })
    print("MERGED")
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
    print("CREATED")

with open(hooks_file, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF3

ok "Session hook configured"

# ── Step 9: Append vector-memory block to CLAUDE.md ─────────────────────────
info "Updating CLAUDE.md..."
CLAUDE_MD="${PROJECT_PATH}/CLAUDE.md"

python3 - "$CLAUDE_MD" "$PROJECT_NAME" "$REPO_DIR" "$SCRIPTS_DIR" "$PROJECT_PATH" <<'PYEOF4'
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
        print("EXISTS")
        sys.exit(0)
    content = content.rstrip() + "\n\n" + vector_block + "\n"
    print("APPENDED")
else:
    project_title = os.path.basename(project_path)
    content = f"# {project_title}\n\n{vector_block}\n"
    print("CREATED")

with open(claude_md, "w") as f:
    f.write(content)
PYEOF4

ok "CLAUDE.md configured"

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
```

- [ ] **Step 2: Make install.sh executable and verify syntax**

```bash
chmod +x install.sh
bash -n install.sh
```
Expected: No output (syntax OK)

- [ ] **Step 3: Commit**

```bash
git add install.sh
git commit -m "feat: rewrite installer — one command sets up any project"
```

---

### Task 2: Create `uninstall.sh`

**Files:**
- Create: `uninstall.sh`

Clean removal for when a user wants to disconnect vector-memory from a project. Uses `sys.argv` for safe path handling (no shell interpolation into Python strings).

- [ ] **Step 1: Write uninstall.sh**

```bash
#!/usr/bin/env bash
# vector-memory uninstaller
# Usage: ./uninstall.sh <project-path>
# Removes MCP config, hooks, reindex script, and CLAUDE.md section.
# Does NOT delete Qdrant data or the global skill.

set -euo pipefail

if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BLUE=''; NC=''
fi

ok()   { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${BLUE}→${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

echo ""
echo "  vector-memory uninstaller"
echo "  ─────────────────────────────────────────"
echo ""

if [[ $# -lt 1 ]]; then
  echo "Usage: ./uninstall.sh <project-path>"
  exit 1
fi

if [[ ! -d "$1" ]]; then
  fail "Project path does not exist: $1"
fi

PROJECT_PATH="$(cd "$1" && pwd)"

# 1. Remove qdrant from .mcp.json
MCP_FILE="${PROJECT_PATH}/.mcp.json"
if [[ -f "$MCP_FILE" ]]; then
  python3 - "$MCP_FILE" <<'PYEOF'
import json, sys, os
mcp_file = sys.argv[1]
with open(mcp_file) as f:
    data = json.load(f)
servers = data.get("mcpServers", {})
if "qdrant" in servers:
    del servers["qdrant"]
if not servers:
    data.pop("mcpServers", None)
if data:
    with open(mcp_file, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
else:
    os.remove(mcp_file)
PYEOF
  ok "Removed qdrant from .mcp.json"
fi

# 2. Remove session-reindex hook from hooks.json
HOOKS_FILE="${PROJECT_PATH}/.claude/hooks.json"
if [[ -f "$HOOKS_FILE" ]]; then
  python3 - "$HOOKS_FILE" <<'PYEOF'
import json, sys, os
hooks_file = sys.argv[1]
with open(hooks_file) as f:
    data = json.load(f)
hooks = data.get("hooks", {})
if "SessionStart" in hooks:
    hooks["SessionStart"] = [
        h for h in hooks["SessionStart"]
        if "session-reindex" not in h.get("command", "")
    ]
    if not hooks["SessionStart"]:
        del hooks["SessionStart"]
if not hooks:
    data.pop("hooks", None)
if data:
    with open(hooks_file, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
else:
    os.remove(hooks_file)
PYEOF
  ok "Removed session-reindex from hooks.json"
fi

# 3. Remove tools/vector-memory directory
HOOKS_DIR="${PROJECT_PATH}/tools/vector-memory"
if [[ -d "$HOOKS_DIR" ]]; then
  rm -rf "$HOOKS_DIR"
  # Remove tools/ if now empty
  rmdir "${PROJECT_PATH}/tools" 2>/dev/null || true
  ok "Removed tools/vector-memory/"
fi

# 4. Remove Vector Memory section from CLAUDE.md
CLAUDE_MD="${PROJECT_PATH}/CLAUDE.md"
if [[ -f "$CLAUDE_MD" ]]; then
  python3 - "$CLAUDE_MD" <<'PYEOF'
import re, sys
claude_md = sys.argv[1]
with open(claude_md) as f:
    text = f.read()
if "## Vector Memory (Qdrant)" not in text:
    sys.exit(0)
# Match from "## Vector Memory (Qdrant)" to the next same-level heading or EOF
# Uses a lookahead for \n## (a heading at the same level) to avoid eating the next section
pattern = r'\n*## Vector Memory \(Qdrant\)\n.*?(?=\n## [^#]|\Z)'
text = re.sub(pattern, '', text, count=1, flags=re.DOTALL)
text = text.rstrip() + '\n'
with open(claude_md, 'w') as f:
    f.write(text)
PYEOF
  ok "Removed Vector Memory section from CLAUDE.md"
fi

echo ""
echo -e "${GREEN}Uninstall complete.${NC} Qdrant data is preserved — to delete it:"
echo "  docker stop qdrant && docker rm qdrant"
echo "  rm -rf ~/.qdrant"
echo ""
```

- [ ] **Step 2: Make it executable and verify syntax**

```bash
chmod +x uninstall.sh
bash -n uninstall.sh
```
Expected: No output (syntax OK)

- [ ] **Step 3: Commit**

```bash
git add uninstall.sh
git commit -m "feat: add uninstall.sh for clean project removal"
```

---

### Task 3: Rewrite `skill/SKILL.md`

**Files:**
- Modify: `skill/SKILL.md`

The current skill has redundant sections (always-on mode, session hooks) that belong in the README, not the skill. The skill should be focused: when to search, when to store, exact formats. Key fix: no hardcoded repo paths — use dynamic lookup from `.mcp.json` presence.

- [ ] **Step 1: Write the new SKILL.md**

Replace `skill/SKILL.md` with:

```markdown
---
name: vector-memory
description: Semantic codebase search and persistent knowledge store via Qdrant. Search before answering, store after solving.
triggers: vector-memory, search codebase, remember this, store this, what do you know about, qdrant
---

# Vector Memory

## On Invoke

1. **Verify Qdrant is running:**
   ```bash
   docker ps --filter "name=qdrant" --format "{{.Names}}"
   ```
   - Output contains `qdrant` → proceed
   - Empty → run `docker start qdrant`, wait 3s, retry
   - Still empty → tell user: run `install.sh` from the vector-memory repo to set up Qdrant

2. **Read collection name:**
   ```bash
   python3 -c "
   import json, sys
   try:
       d = json.load(open('.mcp.json'))
       print(d['mcpServers']['qdrant']['env']['COLLECTION_NAME'])
   except (FileNotFoundError, KeyError):
       print('NOT_CONFIGURED')
   "
   ```
   - If output is `NOT_CONFIGURED` → tell user: run `install.sh <project-path>` from the vector-memory repo

---

## Search Rules

**Use `qdrant-find` FIRST for any codebase question.** Do not grep, glob, or read directory trees until you have searched.

Search triggers — if the user asks anything matching these patterns, search before responding:
- "where is X" / "find X" / "show me X"
- "how does X work"
- "what handles / processes / manages X"
- Any question about code structure, architecture, or implementation

**After search:** Read the returned file paths with the Read tool. Cite file and line range in your answer.

**When search returns nothing useful:** Fall back to grep/glob. Then store the insight you eventually find so future searches work better.

---

## Store Rules

**Use `qdrant-store` after any of these events:**
- Fixed a bug (store root cause + fix)
- Made an architectural decision (store what + why)
- Discovered how something non-obvious works (store the insight)
- Found something that took more than 2 minutes to locate (store the shortcut)

**Format:**
```
[YYYY-MM-DD] <one-line summary>
Root cause: <what was happening>
Fix / decision: <what was done>
Key files: <file:line references>
```

---

## Session Rules

1. **Search before answering** — never guess file locations
2. **Store after solving** — if it took effort, save it
3. **Cite sources** — mention file:line when answering from results
4. **Don't re-search** — reuse results from earlier in the session
5. **Prefer qdrant-find over grep** — vector search finds by meaning, not just keywords
```

- [ ] **Step 2: Commit**

```bash
git add skill/SKILL.md
git commit -m "refactor: tighten SKILL.md — focused search/store rules, no hardcoded paths"
```

---

### Task 4: Delete Templates Directory

**Files:**
- Delete: `templates/.mcp.json.template`
- Delete: `templates/hooks.json.template`
- Delete: `templates/session-reindex.sh.template`

The installer now generates these files directly — templates are dead code.

- [ ] **Step 1: Remove templates directory**

```bash
rm -rf templates/
```

- [ ] **Step 2: Verify no other files reference templates/**

```bash
grep -r "templates/" --include="*.sh" --include="*.md" --include="*.py" . 2>/dev/null | grep -v ".git/"
```
Expected: No output (no remaining references)

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "chore: remove templates dir — installer generates files directly"
```

---

### Task 5: Rewrite README.md

**Files:**
- Modify: `README.md`

Simplify to: clone, run one command, done. Remove the 6-step manual setup and template copy instructions.

- [ ] **Step 1: Write the new README.md**

Replace `README.md` with:

```markdown
# vector-memory

> Semantic codebase search + persistent memory for Claude Code — powered by Qdrant.

## Setup

```bash
git clone https://github.com/yashiels/vector-memory
cd vector-memory
./install.sh /path/to/your/project
```

That's it. The installer:
1. Starts Qdrant (Docker)
2. Installs the Python indexer
3. Installs the Claude Code skill
4. Writes `.mcp.json` to your project
5. Sets up session hooks (auto-reindex on every session)
6. Adds vector-memory instructions to your project's `CLAUDE.md`
7. Runs the first full index

Restart Claude Code after install.

## Usage

Just ask Claude about your codebase — it searches automatically:
> "Where is payment routing handled?"
> "Find the authentication middleware"
> "How does the settlement calculator work?"

Store insights for future sessions:
> "Remember that fuel_type comes from vehicles table, not fuel_logs"

Or invoke the skill explicitly: `/vector-memory`

## How It Works

```
┌─────────────────────────────────────────────────────┐
│                  Claude Code Session                │
│                                                     │
│  ┌──────────────┐  MCP tools  ┌─────────────────┐   │
│  │  qdrant-mcp  │◄───────────►│  Qdrant Docker  │   │
│  │  server      │             │  :6333          │   │
│  └──────────────┘             └─────────────────┘   │
│                                     ▲               │
│                          index_codebase.py          │
│                          (embeds your source files) │
└─────────────────────────────────────────────────────┘
```

- **`qdrant-find`** — semantic search. Ask by meaning, get exact file + line references.
- **`qdrant-store`** — save decisions, bug fixes, insights. Retrieved in future sessions.
- **Smart chunking** — splits at function/class boundaries (40-80 line windows).
- **Incremental indexing** — only re-embeds changed files (git diff).
- **Session hooks** — auto-starts Qdrant and reindexes on every session start.

## Re-indexing

Session hooks handle this automatically. For manual runs:

```bash
cd /path/to/vector-memory/scripts && source .venv/bin/activate

# Incremental (fast — only changed files)
VECTOR_MEMORY_WORKSPACE=/path/to/project python3 index_codebase.py --incremental

# Full rebuild (after large refactors)
VECTOR_MEMORY_WORKSPACE=/path/to/project python3 index_codebase.py --clean
```

## Uninstall

```bash
./uninstall.sh /path/to/your/project
```

Removes MCP config, hooks, and CLAUDE.md section. Qdrant data is preserved.

## Requirements

- [Docker](https://docs.docker.com/get-docker/)
- [Claude Code](https://claude.ai/code)
- Python 3.11+
- `uv` (auto-installed if missing)

## File Types Indexed

`.kt` `.java` `.ts` `.tsx` `.js` `.jsx` `.py` `.go` `.rs` `.rb` `.sql` `.md` `.yaml` `.yml` `.json` `.properties` `.xml` `.gradle` `.sh` `.tf` `.toml`

Excluded: `node_modules/`, `.git/`, `dist/`, `build/`, `.venv/`, `.turbo/`, lock files, minified files.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `VECTOR_MEMORY_WORKSPACE` | current directory | Path to index |
| `VECTOR_MEMORY_COLLECTION` | workspace directory name | Qdrant collection name |
| `VECTOR_MEMORY_QDRANT_URL` | `http://localhost:6333` | Qdrant URL |

## License

MIT — see [LICENSE](LICENSE)
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README — one command setup, remove manual steps"
```

---

### Task 6: Final Verification and Push

- [ ] **Step 1: Verify the full repo state**

```bash
find . -type f -not -path './.git/*' -not -path './scripts/.venv/*' -not -path './scripts/.qdrant-index-state.json' | sort
```

Expected output:
```
./.gitignore
./docker/docker-compose.yml
./docs/superpowers/plans/2026-04-30-vector-memory-easy-setup.md
./install.sh
./LICENSE
./README.md
./scripts/index_codebase.py
./scripts/requirements.txt
./skill/SKILL.md
./uninstall.sh
```

- [ ] **Step 2: Run syntax check on both scripts**

```bash
bash -n install.sh && echo "install.sh OK"
bash -n uninstall.sh && echo "uninstall.sh OK"
```
Expected: Both print OK

- [ ] **Step 3: Commit any remaining changes**

```bash
git status
# Only commit if there are uncommitted changes
git add -A && git commit -m "chore: final cleanup"
```

- [ ] **Step 4: Push all commits**

```bash
git push origin main
```
