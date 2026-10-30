"""공통 계약(contracts/)과 샘플(fixtures/)을 검증한다.

실행: uv run python tools/validate_contracts.py

- 스키마 자체가 Draft 2020-12 규격에 맞는지 확인한다.
- contracts/stats/ 의 통계표는 "stats" 값과 같은 이름의 스키마와 사전 코드로 확인한다 (D-017).
- fixtures/valid/<스키마>/ 의 샘플은 스키마 검증과 의미 검증을 모두 통과해야 한다.
- fixtures/invalid/<스키마>/ 의 샘플은 {"_expect": ..., "data": ...} 형식이며,
  _expect.keyword/_expect.path 의 스키마 오류 또는 _expect.semantic 의 의미 규칙으로 거부돼야 한다.

스키마 통과는 날짜 해석·원문 근거·지원 조건의 정확성을 뜻하지 않는다 (SPEC §6).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource

ROOT = Path(__file__).resolve().parent.parent
CONTRACTS = ROOT / "contracts"
FIXTURES = ROOT / "fixtures"
BASE = "https://gwittim.invalid/contracts/"


def load(path: Path):
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def build_registry() -> tuple[Registry, dict[str, dict]]:
    schemas = {p.name.removesuffix(".schema.json"): load(p) for p in sorted(CONTRACTS.glob("*.schema.json"))}
    registry = Registry().with_resources(
        (BASE + name + ".schema.json", Resource.from_contents(schema)) for name, schema in schemas.items()
    )
    return registry, schemas


def load_dictionaries() -> dict[str, set[str]]:
    codes: dict[str, set[str]] = {}
    for path in sorted((CONTRACTS / "dictionaries").glob("*.json")):
        d = load(path)
        codes[d["dictionary"]] = {item["id"] for item in d["items"]}
    return codes


# ---------- 의미 검증 ----------

def _walk(obj, path=""):
    yield path, obj
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from _walk(v, f"{path}/{k}")
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from _walk(v, f"{path}/{i}")


DICT_FIELDS = {
    "university_id": "universities",
    "major_id": "majors",
    "category": "categories",
    "interest_ids": "interests",
    "interest_tags": "interests",
    "target_role_ids": "roles",
    "related_roles": "roles",
    "related_majors": "majors",
}


def check_dictionary_codes(data, dicts) -> list[str]:
    """사전 코드 필드의 값이 contracts/dictionaries 에 있는지 확인."""
    errors = []
    for path, value in _walk(data):
        key = path.rsplit("/", 1)[-1]
        if key not in DICT_FIELDS or value is None:
            continue
        allowed = dicts.get(DICT_FIELDS[key], set())
        for code in value if isinstance(value, list) else [value]:
            if code not in allowed:
                errors.append(f"dictionary_code: {path} = {code!r} 가 {DICT_FIELDS[key]} 사전에 없음")
    # 조건의 value 는 field 에 따라 사전 확인
    for path, value in _walk(data):
        if isinstance(value, dict) and value.get("field") in ("university_id", "major_id") and "operator" in value:
            allowed = dicts[DICT_FIELDS[value["field"]]]
            vals = value["value"] if isinstance(value["value"], list) else [value["value"]]
            errors += [f"dictionary_code: {path}/value = {v!r} 가 사전에 없음" for v in vals if v not in allowed]
    return errors


def check_eligibility_status(data) -> list[str]:
    """SPEC §6 지원 조건: not_met 하나라도 → not_met, 아니면 unknown 있음 → needs_check, 전부 met → met."""
    errors = []
    for path, value in _walk(data):
        if not (isinstance(value, dict) and "eligibility_status" in value and "condition_results" in value):
            continue
        statuses = [c["status"] for c in value["condition_results"]]
        if not statuses:
            # 조건 없음: 명시적 제한 없음 여부는 Notice 에 있으므로 not_met 만 금지
            expected = {"met", "needs_check"}
        elif "not_met" in statuses:
            expected = {"not_met"}
        elif "unknown" in statuses:
            expected = {"needs_check"}
        else:
            # 판정 결과가 모두 met이어도 미해석 조건·불완전 추출(Notice 쪽 정보)이 있으면 needs_check
            expected = {"met", "needs_check"}
        if value["eligibility_status"] not in expected:
            errors.append(f"eligibility_status: {path} = {value['eligibility_status']!r}, 조건 판정 {statuses} 와 맞지 않음")
    return errors


def semantic_errors(data, dicts) -> list[str]:
    return check_dictionary_codes(data, dicts) + check_eligibility_status(data)


def check_major_prior(data, dicts) -> list[str]:
    """학과 통계 확률표(D-017): 코드가 사전에 있고, 학과마다 확률 합이 1에 가깝다."""
    errors = []
    for major_id, m in data["majors"].items():
        if major_id not in dicts["majors"]:
            errors.append(f"major_prior: {major_id!r} 가 majors 사전에 없음")
        for key, dictionary in (("roles", "roles"), ("interests", "interests")):
            unknown = sorted(set(m[key]) - dicts[dictionary])
            if unknown:
                errors.append(f"major_prior: {major_id}/{key} {unknown} 가 {dictionary} 사전에 없음")
            if abs(sum(m[key].values()) - 1) > 0.01:
                errors.append(f"major_prior: {major_id}/{key} 확률 합 {sum(m[key].values()):.3f}")
    return errors


# ---------- 실행 ----------

def all_errors(error):
    yield error
    for sub in error.context or []:
        yield from all_errors(sub)


def main() -> int:
    registry, schemas = build_registry()
    dicts = load_dictionaries()
    failures: list[str] = []
    counts = {"schemas": 0, "dictionaries": 0, "stats": 0, "valid_pass": 0, "invalid_rejected": 0}

    for name, schema in schemas.items():
        Draft202012Validator.check_schema(schema)
        counts["schemas"] += 1
    validators = {
        name: Draft202012Validator(schema, registry=registry, format_checker=FormatChecker())
        for name, schema in schemas.items()
    }

    for path in sorted((CONTRACTS / "dictionaries").glob("*.json")):
        errs = list(validators["dictionary"].iter_errors(load(path)))
        if errs:
            failures.append(f"[dictionary] {path.name}: {errs[0].message}")
        else:
            counts["dictionaries"] += 1

    for path in sorted((CONTRACTS / "stats").glob("*.json")):
        data = load(path)
        errs = [e.message for e in validators[data["stats"]].iter_errors(data)] or check_major_prior(data, dicts)
        if errs:
            failures.append(f"[stats] {path.name}: {errs[0]}")
        else:
            counts["stats"] += 1

    for path in sorted(FIXTURES.glob("valid/*/*.json")):
        schema_name = path.parent.name
        data = load(path)
        errs = [f"{'/'.join(map(str, e.absolute_path))}: {e.message}" for e in validators[schema_name].iter_errors(data)]
        errs += semantic_errors(data, dicts)
        rel = path.relative_to(ROOT).as_posix()
        if errs:
            failures.append(f"[valid 실패] {rel}: " + "; ".join(errs[:3]))
        else:
            counts["valid_pass"] += 1

    for path in sorted(FIXTURES.glob("invalid/*/*.json")):
        schema_name = path.parent.name
        wrapper = load(path)
        expect, data = wrapper["_expect"], wrapper["data"]
        rel = path.relative_to(ROOT).as_posix()
        schema_errs = list(validators[schema_name].iter_errors(data))
        if "semantic" in expect:
            sem = [e for e in semantic_errors(data, dicts) if e.startswith(expect["semantic"] + ":")]
            if schema_errs:
                failures.append(f"[invalid] {rel}: 의미 오류를 기대했으나 스키마 오류 발생: {schema_errs[0].message}")
            elif not sem:
                failures.append(f"[invalid 통과됨] {rel}: 의미 규칙 {expect['semantic']} 로 거부되지 않음")
            else:
                counts["invalid_rejected"] += 1
            continue
        matched = [
            e
            for top in schema_errs
            for e in all_errors(top)
            if e.validator == expect["keyword"] and "/".join(map(str, e.absolute_path)).startswith(expect["path"])
        ]
        if not schema_errs:
            failures.append(f"[invalid 통과됨] {rel}: 스키마가 거부하지 않음")
        elif not matched:
            got = [f"{e.validator}@{'/'.join(map(str, e.absolute_path))}" for top in schema_errs for e in all_errors(top)]
            failures.append(f"[invalid] {rel}: 기대 {expect['keyword']}@{expect['path']}, 실제 {got[:5]}")
        else:
            counts["invalid_rejected"] += 1

    print(
        f"schemas {counts['schemas']} OK, dictionaries {counts['dictionaries']} OK, stats {counts['stats']} OK, "
        f"valid fixtures {counts['valid_pass']} passed, invalid fixtures {counts['invalid_rejected']} rejected as expected"
    )
    for f in failures:
        print("FAIL", f)
    print("결과:", "실패 " + str(len(failures)) + "건" if failures else "전체 통과")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
