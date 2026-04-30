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
