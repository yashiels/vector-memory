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
