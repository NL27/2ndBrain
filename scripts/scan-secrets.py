#!/usr/bin/env python3
"""Find likely secrets in the vault, overnight drop folder, and this repo.

Prints path + kind only. Never prints the matching text.
"""
from __future__ import annotations

import argparse
import os
import re
from pathlib import Path

PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("openai-key", re.compile(r"sk-[A-Za-z0-9_-]{16,}")),
    ("openrouter-key", re.compile(r"sk-or-[A-Za-z0-9_-]{16,}")),
    ("anthropic-key", re.compile(r"sk-ant-[A-Za-z0-9_-]{16,}")),
    ("github-pat", re.compile(r"ghp_[A-Za-z0-9]{20,}")),
    ("github-fine-grained", re.compile(r"github_pat_[A-Za-z0-9_]{20,}")),
    ("huggingface-token", re.compile(r"hf_[A-Za-z0-9]{20,}")),
    ("slack-token", re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}")),
    ("aws-access-key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("jwt", re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+")),
    ("private-key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----")),
    ("n8n-env-token", re.compile(r"(?i)N8N_[A-Z0-9_]*TOKEN\s*=\s*\S{24,}")),
]

SKIP_DIRS = {
    ".obsidian", "node_modules", ".git", ".build", ".swiftpm", "dist",
    "Agent Skills", "__pycache__",
}
SKIP_SUFFIX = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".mov", ".m4a", ".wav",
               ".icns", ".woff", ".woff2", ".bin", ".gguf"}


def should_skip(path: Path) -> bool:
    if path.suffix.lower() in SKIP_SUFFIX:
        return True
    return any(part in SKIP_DIRS for part in path.parts)


def scan_file(path: Path) -> list[str]:
    try:
        if path.stat().st_size > 2_000_000:
            return []
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return []
    hits = []
    for kind, pattern in PATTERNS:
        if pattern.search(text):
            hits.append(kind)
    return hits


def walk(root: Path) -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    if not root.exists():
        return found
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            path = Path(dirpath) / name
            if should_skip(path):
                continue
            for kind in scan_file(path):
                found.append((str(path), kind))
    return found


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vault", default=str(Path.home() / "Desktop/2nd Brain"))
    parser.add_argument("--drop", default="/Users/Shared/2nd-Brain-Night")
    parser.add_argument("--repo", default="")
    args = parser.parse_args()

    roots = [Path(args.vault), Path(args.drop)]
    if args.repo:
        roots.append(Path(args.repo))
    else:
        here = Path(__file__).resolve().parent.parent
        if (here / ".git").exists():
            roots.append(here)

    hits: list[tuple[str, str]] = []
    for root in roots:
        hits.extend(walk(root))

    if not hits:
        print("no likely secrets in vault, drop folder, or repo")
        return 0

    print(f"{len(hits)} likely secret(s) — values not shown:")
    for path, kind in hits:
        print(f"  {kind:22} {path}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
