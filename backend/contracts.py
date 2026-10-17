"""contracts/ JSON Schema 로더. 백엔드 모듈이 같은 계약으로 입출력을 검증할 때 쓴다."""
from __future__ import annotations

import json
from functools import cache
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource

CONTRACTS_DIR = Path(__file__).resolve().parent.parent / "contracts"
_BASE = "https://gwittim.invalid/contracts/"


@cache
def _registry() -> Registry:
    resources = []
    for path in CONTRACTS_DIR.glob("*.schema.json"):
        with path.open(encoding="utf-8") as f:
            resources.append((_BASE + path.name, Resource.from_contents(json.load(f))))
    return Registry().with_resources(resources)


@cache
def validator(name: str) -> Draft202012Validator:
    """예: validator("raw_notice")"""
    with (CONTRACTS_DIR / f"{name}.schema.json").open(encoding="utf-8") as f:
        schema = json.load(f)
    return Draft202012Validator(schema, registry=_registry(), format_checker=FormatChecker())


def schema_errors(name: str, data) -> list[str]:
    return [
        f"{'/'.join(map(str, e.absolute_path)) or '(root)'}: {e.message}"
        for e in validator(name).iter_errors(data)
    ]
