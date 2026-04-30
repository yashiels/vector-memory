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
