#!/usr/bin/env python3
"""Dependency-free validation for the bundled Phase 0 JSON Schemas."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


class ContractError(ValueError):
    pass


def type_matches(value, expected: str) -> bool:
    return {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
        "boolean": isinstance(value, bool),
        "null": value is None,
    }[expected]


def validate(instance, schema, registry, root=None, path="$", combinators=True):
    root = root or schema
    if "$ref" in schema:
        ref = schema["$ref"]
        if ref.startswith("#/"):
            target = root
            for part in ref[2:].split("/"):
                target = target[part.replace("~1", "/").replace("~0", "~")]
            return validate(instance, target, registry, root, path)
        target = registry[ref]
        return validate(instance, target, registry, target, path)
    if "const" in schema and instance != schema["const"]:
        raise ContractError(f"{path}: expected {schema['const']!r}")
    if "enum" in schema and instance not in schema["enum"]:
        raise ContractError(f"{path}: value is outside the allowed enum")
    expected = schema.get("type")
    if expected:
        choices = expected if isinstance(expected, list) else [expected]
        if not any(type_matches(instance, choice) for choice in choices):
            raise ContractError(f"{path}: expected {choices}, got {type(instance).__name__}")
    if isinstance(instance, dict):
        for key in schema.get("required", []):
            if key not in instance:
                raise ContractError(f"{path}: missing required property {key}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            unknown = set(instance) - set(properties)
            if unknown:
                raise ContractError(f"{path}: unknown properties {sorted(unknown)}")
        for key, value in instance.items():
            if key in properties:
                validate(value, properties[key], registry, root, f"{path}.{key}")
            elif isinstance(schema.get("additionalProperties"), dict):
                validate(value, schema["additionalProperties"], registry, root, f"{path}.{key}")
        if len(instance) > schema.get("maxProperties", float("inf")):
            raise ContractError(f"{path}: too many properties")
        if "propertyNames" in schema:
            for key in instance:
                validate(key, schema["propertyNames"], registry, root, f"{path}.<key>")
    if isinstance(instance, list):
        if not schema.get("minItems", 0) <= len(instance) <= schema.get("maxItems", float("inf")):
            raise ContractError(f"{path}: array size is out of bounds")
        if schema.get("uniqueItems"):
            encoded = [json.dumps(item, sort_keys=True) for item in instance]
            if len(encoded) != len(set(encoded)):
                raise ContractError(f"{path}: array items are not unique")
        if "items" in schema:
            for index, item in enumerate(instance):
                validate(item, schema["items"], registry, root, f"{path}[{index}]")
    if isinstance(instance, str):
        if len(instance) < schema.get("minLength", 0):
            raise ContractError(f"{path}: string is too short")
        if "pattern" in schema and not re.search(schema["pattern"], instance):
            raise ContractError(f"{path}: string does not match the required pattern")
    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if instance < schema.get("minimum", float("-inf")) or instance > schema.get("maximum", float("inf")):
            raise ContractError(f"{path}: number is out of bounds")
    if combinators:
        for branch in schema.get("allOf", []):
            if "if" in branch:
                try:
                    validate(instance, branch["if"], registry, root, path, False)
                    matched = True
                except ContractError:
                    matched = False
                if matched and "then" in branch:
                    validate(instance, branch["then"], registry, root, path)
            else:
                validate(instance, branch, registry, root, path)
        if "oneOf" in schema:
            matches = 0
            for branch in schema["oneOf"]:
                try:
                    validate(instance, branch, registry, root, path)
                    matches += 1
                except ContractError:
                    pass
            if matches != 1:
                raise ContractError(f"{path}: expected one matching oneOf branch")
        if "anyOf" in schema:
            for branch in schema["anyOf"]:
                try:
                    validate(instance, branch, registry, root, path)
                    break
                except ContractError:
                    pass
            else:
                raise ContractError(f"{path}: expected a matching anyOf branch")
        if "not" in schema:
            try:
                validate(instance, schema["not"], registry, root, path)
            except ContractError:
                pass
            else:
                raise ContractError(f"{path}: matched a forbidden schema")


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print("usage: validate-check-result.py SCHEMA_DIR RESULT [SCHEMA_FILE]", file=sys.stderr)
        return 2
    schema_dir = Path(sys.argv[1])
    schema_file = sys.argv[3] if len(sys.argv) == 4 else "check-result.schema.json"
    registry = {}
    for path in schema_dir.glob("*.schema.json"):
        schema = json.loads(path.read_text())
        registry[path.name] = schema
        registry[schema["$id"]] = schema
    try:
        instance = json.loads(Path(sys.argv[2]).read_text())
        validate(instance, registry[schema_file], registry)
    except (OSError, json.JSONDecodeError, KeyError, ContractError) as error:
        print(f"invalid Polyglot check result: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
