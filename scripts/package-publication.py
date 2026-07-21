#!/usr/bin/env python3
"""Fail-closed diff validation and report/artifact packaging."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path


def fail(message: str) -> None:
    raise ValueError(message)


def digest(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def safe_path(root: Path, relative: str) -> Path:
    candidate = Path(relative)
    if not relative or candidate.is_absolute() or "\\" in relative or any(
        part in ("", ".", "..") for part in candidate.parts
    ):
        fail("publication contains an unsafe path")
    current = root
    for part in candidate.parts:
        current = current / part
        if current.is_symlink():
            fail("publication path traverses a symlink")
    resolved = current.resolve(strict=True)
    if root not in resolved.parents:
        fail("publication path escaped the checkout")
    return resolved


def changed_paths(root: Path) -> set[str]:
    output = subprocess.run(
        ["git", "-C", str(root), "status", "--porcelain=v1", "-z", "--untracked-files=all"],
        check=True,
        stdout=subprocess.PIPE,
    ).stdout
    records = output.split(b"\0")
    changed: set[str] = set()
    index = 0
    while index < len(records) and records[index]:
        record = records[index]
        if len(record) < 4:
            fail("Git returned an invalid publication diff")
        status = record[:2]
        changed.add(record[3:].decode("utf-8"))
        if b"R" in status or b"C" in status:
            fail("publication verification may not rename or copy repository paths")
        index += 1
    return changed


def main() -> int:
    if len(sys.argv) != 5:
        print("usage: package-publication.py WORKSPACE MANIFEST REPORT OUTPUT", file=sys.stderr)
        return 2
    root = Path(sys.argv[1]).resolve(strict=True)
    manifest = json.loads(Path(sys.argv[2]).read_text())
    report = json.loads(Path(sys.argv[3]).read_text())
    output = Path(sys.argv[4])

    if report["status"] != "verified" or report["dry_run"] is not False:
        fail("only a verified non-dry-run publication can upload catalog artifacts")
    if report["run_id"] != manifest["run_id"]:
        fail("publication report run identity does not match its manifest")

    allowed = set(manifest["allowed_paths"])
    changed = changed_paths(root)
    reported = {item["path"] for item in report["changed_files"]}
    if not changed <= allowed or changed != reported:
        fail("publication diff does not exactly match the reported catalog paths")

    files = []
    for item in sorted(report["changed_files"], key=lambda value: value["path"]):
        path = safe_path(root, item["path"])
        content = path.read_bytes()
        if len(content) > manifest["limits"]["max_file_bytes"]:
            fail("publication artifact exceeds its signed size limit")
        if digest(content) != item["after_hash"]:
            fail("publication artifact does not match its reported after hash")
        files.append(
            {
                "path": item["path"],
                "content_base64": base64.b64encode(content).decode("ascii"),
                "after_hash": item["after_hash"],
            }
        )

    payload = {"schema_version": 1, "report": report, "files": files}
    output.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, KeyError, UnicodeDecodeError, ValueError, subprocess.SubprocessError) as error:
        print(f"invalid Polyglot publication: {error}", file=sys.stderr)
        raise SystemExit(1)
