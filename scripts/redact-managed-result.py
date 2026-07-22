#!/usr/bin/env python3
"""Remove raw finding values before a managed result leaves the runner."""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import os
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: redact-managed-result.py INPUT OUTPUT", file=sys.stderr)
        return 2

    source = Path(sys.argv[1])
    destination = Path(sys.argv[2])

    try:
        encoded_key = os.environ["POLYGLOT_FINDING_HASH_KEY"]
        padding = "=" * (-len(encoded_key) % 4)
        key = base64.urlsafe_b64decode(encoded_key + padding)
        if len(key) != 32:
            raise ValueError("finding hash key must decode to 32 bytes")

        result = json.loads(source.read_text())
        findings = result["findings"]
        if not isinstance(findings, list):
            raise ValueError("findings must be an array")

        for finding in findings:
            value = finding.pop("value")
            if not isinstance(value, str):
                raise ValueError("finding value must be a string")
            digest = hmac.new(key, value.encode("utf-8"), hashlib.sha256).hexdigest()
            finding["value_hash"] = f"hmac-sha256:{digest}"

        destination.write_text(
            json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n"
        )
    except (
        OSError,
        KeyError,
        TypeError,
        ValueError,
        json.JSONDecodeError,
        binascii.Error,
    ) as error:
        print(f"could not redact managed result: {error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
