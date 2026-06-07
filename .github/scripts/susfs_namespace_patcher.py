#!/usr/bin/env python3
"""Small idempotent namespace.c helper for SuSFS patch drift.

The upstream SuSFS patch occasionally misses one namespace.c hunk on Android
common 6.1 trees. This helper performs the safe part used by this workflow:
ensure the trace hook include exists, and leave the file untouched otherwise.
It is deliberately conservative so it can be run after a normal patch without
creating duplicate edits.
"""
from __future__ import annotations

import argparse
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", help="path to fs/namespace.c")
    parser.add_argument("--no-backup", action="store_true")
    args = parser.parse_args()

    path = Path(args.path)
    if not path.exists():
        raise SystemExit(f"{path} does not exist")

    text = path.read_text()
    if "#include <trace/hooks/blk.h>" in text:
        return 0

    marker = '#include "internal.h"\n'
    if marker not in text:
        raise SystemExit("namespace.c layout drifted; internal.h include marker not found")

    if not args.no_backup:
        backup = path.with_suffix(path.suffix + ".bak")
        backup.write_text(text)

    path.write_text(text.replace(marker, marker + "#include <trace/hooks/blk.h>\n", 1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
