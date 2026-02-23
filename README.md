# vector-memory

> Semantic codebase search + persistent session memory for Claude Code — powered by Qdrant.

Give Claude Code a long-term memory. It searches your codebase by meaning (not just keywords) and remembers decisions, fixes, and insights across sessions.

---

## How It Works

```
┌─────────────────────────────────────────────────────┐
│                  Claude Code Session                │
│                                                     │
│  ┌──────────────┐  MCP tools  ┌─────────────────┐  │
│  │  qdrant-mcp  │◄───────────►│  Qdrant Docker  │  │
│  │  server      │             │  :6333          │  │
│  └──────────────┘             └─────────────────┘  │
│                                     ▲               │
│                          index_codebase.py          │
│                          (embeds your source files) │
└─────────────────────────────────────────────────────┘
```

- **`qdrant-find`** — semantic search across your entire codebase. Ask "where is authentication handled?" and get exact file + line references.
- **`qdrant-store`** — save decisions, bug fixes, and insights. Retrieved in future sessions automatically.
- **`vector-memory` skill** — teaches Claude when to search and what to store. Auto-starts Qdrant on session start.

---

## Requirements

- [Docker](https://docs.docker.com/get-docker/) (any runtime: Docker Desktop, Rancher, OrbStack, Colima, Linux)
- [Claude Code](https://claude.ai/code)
- Python 3.11+
- `uv` (auto-installed by `install.sh` if missing)

---

## Quickstart

```bash
# 1. Clone and install
git clone https://github.com/skyner-group/vector-memory
cd vector-memory
./install.sh

# 2. Add MCP config to your project
cp templates/.mcp.json.template /path/to/your/project/.mcp.json
# Edit .mcp.json and set COLLECTION_NAME to your project name (e.g. "my-app")

# 3. Index your codebase
cd scripts
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
VECTOR_MEMORY_WORKSPACE=/path/to/your/project python3 index_codebase.py

# 4. Restart Claude Code and activate
# Run in Claude Code: /vector-memory
```

---

## Usage

### Activate the skill
```
/vector-memory
```
Claude will check Qdrant is running, read your collection name, and apply search-first rules.

### Search the codebase
Just ask naturally — Claude searches automatically:
> "Where is payment routing handled?"
> "Find the authentication middleware"
> "How does the event bus work?"

### Store a note
> "Remember that we fixed the BUSY state bug by sending a broadcast from finishWithError()"

### Manual search/store
```
Use qdrant-find to search for "database connection pooling"
Use qdrant-store to remember that X is handled in Y
```

---

## Manual Setup

If you prefer to understand each step:

**1. Start Qdrant**
```bash
docker compose -f docker/docker-compose.yml up -d
```

**2. Install uv** (if not already installed)
```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

**3. Install the Claude Code skill**
```bash
mkdir -p ~/.claude/skills/vector-memory
cp skill/SKILL.md ~/.claude/skills/vector-memory/SKILL.md
```

**4. Configure your project**
```bash
cp templates/.mcp.json.template /path/to/your/project/.mcp.json
# Edit and set COLLECTION_NAME
```

**5. Index your codebase**
```bash
cd scripts
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
VECTOR_MEMORY_WORKSPACE=/path/to/project python3 index_codebase.py
```

**6. Restart Claude Code**

---

## Re-indexing

Run after significant code changes:

```bash
cd scripts && source .venv/bin/activate

# Incremental (fast, safe to run anytime)
VECTOR_MEMORY_WORKSPACE=/path/to/project python3 index_codebase.py

# Full rebuild (after large refactors)
VECTOR_MEMORY_WORKSPACE=/path/to/project python3 index_codebase.py --clean
```

---

## Configuration

All indexer settings via environment variables:

| Variable | Default | Description |
|---|---|---|
| `VECTOR_MEMORY_WORKSPACE` | current directory | Path to index |
| `VECTOR_MEMORY_COLLECTION` | workspace directory name | Qdrant collection name |
| `VECTOR_MEMORY_QDRANT_URL` | `http://localhost:6333` | Qdrant URL |

---

## File Types Indexed

`.kt` `.java` `.ts` `.tsx` `.js` `.jsx` `.py` `.go` `.rs` `.rb` `.sql` `.md` `.yaml` `.yml` `.json` `.properties` `.xml` `.gradle` `.sh` `.tf` `.toml`

Excluded: `build/`, `node_modules/`, `.git/`, `.venv/`, `dist/`, `target/`

---

## License

MIT — see [LICENSE](LICENSE)
