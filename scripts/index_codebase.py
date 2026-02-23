#!/usr/bin/env python3
"""
vector-memory: Codebase indexer for Qdrant.

Indexes a workspace directory into a Qdrant vector collection for semantic search.

Configuration via environment variables:
  VECTOR_MEMORY_WORKSPACE    Path to index (default: current directory)
  VECTOR_MEMORY_COLLECTION   Qdrant collection name (default: basename of workspace)
  VECTOR_MEMORY_QDRANT_URL   Qdrant URL (default: http://localhost:6333)

Usage:
  python3 index_codebase.py            # Upsert new/changed files
  python3 index_codebase.py --clean    # Drop collection and rebuild from scratch
  python3 index_codebase.py --dry-run  # Count files without indexing
"""

import argparse
import hashlib
import os
import sys
from pathlib import Path

from qdrant_client import QdrantClient
from qdrant_client.models import Distance, PointStruct, VectorParams

# ── Configuration ────────────────────────────────────────────────────────────

_default_workspace = Path(os.environ.get("VECTOR_MEMORY_WORKSPACE", os.getcwd()))
WORKSPACE = _default_workspace.resolve()

_default_collection = WORKSPACE.name.lower().replace(" ", "-")
COLLECTION_NAME = os.environ.get("VECTOR_MEMORY_COLLECTION", _default_collection)

QDRANT_URL = os.environ.get("VECTOR_MEMORY_QDRANT_URL", "http://localhost:6333")
EMBEDDING_MODEL = "sentence-transformers/all-MiniLM-L6-v2"
VECTOR_SIZE = 384
CHUNK_SIZE = 60
CHUNK_OVERLAP = 10

INCLUDE_EXTENSIONS = {
    ".kt", ".java", ".xml", ".gradle", ".kts",
    ".ts", ".tsx", ".js", ".jsx", ".json",
    ".yaml", ".yml", ".properties", ".sql",
    ".py", ".go", ".rs", ".rb", ".md",
    ".sh", ".tf", ".toml",
}

EXCLUDE_DIRS = {
    "build", ".gradle", "node_modules", ".git",
    ".idea", "generated", "intermediates", "__pycache__",
    ".kotlin", "caches", ".venv", "venv", "dist", ".next",
    "target", ".terraform",
}

# ── Helpers ───────────────────────────────────────────────────────────────────

def should_index(path: Path) -> bool:
    if path.suffix not in INCLUDE_EXTENSIONS:
        return False
    for part in path.parts:
        if part in EXCLUDE_DIRS:
            return False
    return True


def chunk_file(path: Path) -> list[dict]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []

    lines = text.splitlines()
    chunks = []
    step = CHUNK_SIZE - CHUNK_OVERLAP

    for start in range(0, max(1, len(lines) - CHUNK_OVERLAP), step):
        end = min(start + CHUNK_SIZE, len(lines))
        chunk_text = "\n".join(lines[start:end])
        if not chunk_text.strip():
            continue

        chunk_id = hashlib.sha256(
            f"{path}:{start}:{end}:{chunk_text}".encode()
        ).hexdigest()

        try:
            rel = path.relative_to(WORKSPACE)
            repo = rel.parts[0] if len(rel.parts) > 1 else path.name
        except ValueError:
            repo = path.name

        doc = f"File: {path}\nLines: {start+1}-{end}\n\n{chunk_text}"
        chunks.append({
            "id": chunk_id,
            "text": doc,
            "payload": {
                "document": doc,
                "file": str(path),
                "repo": repo,
                "language": path.suffix.lstrip("."),
                "line_start": start + 1,
                "line_end": end,
            },
        })

        if end >= len(lines):
            break

    return chunks


def collect_files(workspace: Path) -> list[Path]:
    files = []
    for root, dirs, filenames in os.walk(workspace):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
        for fname in filenames:
            p = Path(root) / fname
            if should_index(p):
                files.append(p)
    return files


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Index a codebase into Qdrant for semantic search")
    parser.add_argument("--clean", action="store_true", help="Drop and rebuild collection")
    parser.add_argument("--dry-run", action="store_true", help="Count files without indexing")
    args = parser.parse_args()

    print(f"Workspace:  {WORKSPACE}")
    print(f"Collection: {COLLECTION_NAME}")
    print(f"Qdrant:     {QDRANT_URL}")
    print()

    client = QdrantClient(url=QDRANT_URL)

    try:
        client.get_collections()
    except Exception as e:
        print(f"ERROR: Cannot connect to Qdrant at {QDRANT_URL}")
        print(f"  Make sure Qdrant is running: docker compose -f docker/docker-compose.yml up -d")
        print(f"  Details: {e}")
        sys.exit(1)

    if args.clean:
        collections = [c.name for c in client.get_collections().collections]
        if COLLECTION_NAME in collections:
            print(f"Dropping collection '{COLLECTION_NAME}'...")
            client.delete_collection(COLLECTION_NAME)

    collections = [c.name for c in client.get_collections().collections]
    if COLLECTION_NAME not in collections:
        print(f"Creating collection '{COLLECTION_NAME}'...")
        client.create_collection(
            collection_name=COLLECTION_NAME,
            vectors_config={"fast-all-minilm-l6-v2": VectorParams(size=VECTOR_SIZE, distance=Distance.COSINE)},
        )

    print(f"Scanning {WORKSPACE}...")
    files = collect_files(WORKSPACE)
    print(f"Found {len(files)} indexable files")

    if args.dry_run:
        for f in files[:20]:
            try:
                print(f"  {f.relative_to(WORKSPACE)}")
            except ValueError:
                print(f"  {f}")
        if len(files) > 20:
            print(f"  ... and {len(files) - 20} more")
        return

    print("Chunking files...")
    all_chunks = []
    for f in files:
        all_chunks.extend(chunk_file(f))
    print(f"Generated {len(all_chunks)} chunks")

    from fastembed import TextEmbedding
    print(f"Loading embedding model '{EMBEDDING_MODEL}' (first run downloads ~90MB)...")
    embedder = TextEmbedding(model_name=EMBEDDING_MODEL)

    batch_size = 100
    texts = [c["text"] for c in all_chunks]
    total = len(all_chunks)
    indexed = 0

    print(f"Indexing {total} chunks in batches of {batch_size}...")
    for i in range(0, total, batch_size):
        batch_chunks = all_chunks[i : i + batch_size]
        batch_texts = texts[i : i + batch_size]
        embeddings = list(embedder.embed(batch_texts))

        points = [
            PointStruct(
                id=int(c["id"][:8], 16),
                vector={"fast-all-minilm-l6-v2": list(emb)},
                payload=c["payload"],
            )
            for c, emb in zip(batch_chunks, embeddings)
        ]

        client.upsert(collection_name=COLLECTION_NAME, points=points)
        indexed += len(points)
        print(f"  {indexed}/{total} ({indexed/total*100:.0f}%)", end="\r")

    print(f"\nDone. {indexed} chunks indexed into '{COLLECTION_NAME}'.")
    print(f"\nTo search: use the vector-memory skill in Claude Code and ask codebase questions.")


if __name__ == "__main__":
    main()
