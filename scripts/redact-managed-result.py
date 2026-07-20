#!/usr/bin/env python3
"""Remove raw finding values before a managed result leaves the runner."""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: redact-managed-result.py INPUT OUTPUT", file=sys.stderr)
        return 2

    source = Path(sys.argv[1])
    destination = Path(sys.argv[2])

    try:
        result = json.loads(source.read_text())
        findings = result["findings"]
        if not isinstance(findings, list):
            raise ValueError("findings must be an array")

        for finding in findings:
            value = finding.pop("value")
            if not isinstance(value, str):
                raise ValueError("finding value must be a string")
            digest = hashlib.sha256(value.encode("utf-8")).hexdigest()
            finding["value_hash"] = f"sha256:{digest}"

        destination.write_text(
            json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n"
        )
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"could not redact managed result: {error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
