#!/usr/bin/env python3

import argparse
import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent


class ValidationError(Exception):
    pass


def json_equal(lhs: Any, rhs: Any) -> bool:
    if isinstance(lhs, bool) or isinstance(rhs, bool):
        return isinstance(lhs, bool) and isinstance(rhs, bool) and lhs == rhs
    if isinstance(lhs, (int, float)) and isinstance(rhs, (int, float)):
        return lhs == rhs
    return type(lhs) is type(rhs) and lhs == rhs


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def resolve_ref(schema: dict[str, Any], root: dict[str, Any]) -> dict[str, Any]:
    reference = schema.get("$ref")
    if reference is None:
        return schema
    if not reference.startswith("#/"):
        raise ValidationError(f"unsupported reference {reference}")

    value: Any = root
    for part in reference[2:].split("/"):
        value = value[part.replace("~1", "/").replace("~0", "~")]
    if not isinstance(value, dict):
        raise ValidationError(f"reference {reference} did not resolve to an object")
    return value


def validate(value: Any, schema: dict[str, Any], root: dict[str, Any], location: str = "$") -> None:
    schema = resolve_ref(schema, root)

    for item in schema.get("allOf", []):
        validate(value, item, root, location)

    if "oneOf" in schema:
        matches = 0
        for candidate in schema["oneOf"]:
            try:
                validate(value, candidate, root, location)
            except ValidationError:
                continue
            matches += 1
        if matches != 1:
            raise ValidationError(
                f"{location}: expected exactly one oneOf branch, matched {matches}"
            )

    if "const" in schema and not json_equal(value, schema["const"]):
        raise ValidationError(f"{location}: expected constant {schema['const']!r}, got {value!r}")
    if "enum" in schema and not any(json_equal(value, item) for item in schema["enum"]):
        raise ValidationError(f"{location}: {value!r} is not one of {schema['enum']!r}")

    expected_type = schema.get("type")
    if expected_type == "object":
        if not isinstance(value, dict):
            raise ValidationError(f"{location}: expected object")
        required = set(schema.get("required", []))
        missing = required.difference(value)
        if missing:
            raise ValidationError(f"{location}: missing required properties {sorted(missing)!r}")

        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            extra = set(value).difference(properties)
            if extra:
                raise ValidationError(f"{location}: unexpected properties {sorted(extra)!r}")
        for key, item in value.items():
            if key in properties:
                validate(item, properties[key], root, f"{location}.{key}")
        return

    if expected_type == "array":
        if not isinstance(value, list):
            raise ValidationError(f"{location}: expected array")
        item_schema = schema.get("items")
        if item_schema is not None:
            for index, item in enumerate(value):
                validate(item, item_schema, root, f"{location}[{index}]")
        return

    type_matches = {
        "string": lambda candidate: isinstance(candidate, str),
        "integer": lambda candidate: isinstance(candidate, int) and not isinstance(candidate, bool),
        "boolean": lambda candidate: isinstance(candidate, bool),
    }
    if expected_type in type_matches and not type_matches[expected_type](value):
        raise ValidationError(f"{location}: expected {expected_type}")
    if expected_type == "string" and len(value) < schema.get("minLength", 0):
        raise ValidationError(f"{location}: string is shorter than minLength")
    if expected_type == "integer" and value < schema.get("minimum", value):
        raise ValidationError(f"{location}: integer is below minimum")


def validate_file(document_path: Path, schema_path: Path) -> None:
    schema = load_json(schema_path)
    validate(load_json(document_path), schema, schema)
    print(f"PASS {document_path}")


def validate_rejected_file(document_path: Path, schema_path: Path) -> None:
    schema = load_json(schema_path)
    try:
        validate(load_json(document_path), schema, schema)
    except ValidationError:
        print(f"PASS rejected {document_path}")
        return
    raise ValidationError(f"{document_path}: invalid fixture unexpectedly matched its schema")


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate pinentry-companion JSON contracts")
    parser.add_argument("--status", action="append", type=Path, default=[])
    parser.add_argument("--plan", action="append", type=Path, default=[])
    parser.add_argument("--lifecycle", action="append", type=Path, default=[])
    args = parser.parse_args()

    status_files = args.status or sorted((ROOT / "Contracts/Fixtures/status").glob("*.json"))
    plan_files = args.plan or sorted((ROOT / "Contracts/Fixtures/plan").glob("*.json"))
    lifecycle_files = args.lifecycle or sorted(
        (ROOT / "Contracts/Fixtures/lifecycle").glob("*.json")
    )
    status_schema = ROOT / "Contracts/Schemas/status-v1.schema.json"
    plan_schema = ROOT / "Contracts/Schemas/plan-v1.schema.json"
    lifecycle_schema = ROOT / "Contracts/Schemas/lifecycle-mutation-v1.schema.json"
    invalid_lifecycle_files = sorted(
        (ROOT / "Contracts/InvalidFixtures/lifecycle").glob("*.json")
    )

    try:
        for path in status_files:
            validate_file(path, status_schema)
        for path in plan_files:
            validate_file(path, plan_schema)
        for path in lifecycle_files:
            validate_file(path, lifecycle_schema)
        for path in invalid_lifecycle_files:
            validate_rejected_file(path, lifecycle_schema)
    except (OSError, json.JSONDecodeError, KeyError, ValidationError) as error:
        print(f"FAIL {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
