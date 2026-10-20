"""앱 샘플 Repository용 자산을 fixtures에서 만든다. 추천 결과는 백엔드 추천 함수 출력 그대로다.

실행: uv run python -m tools.export_mobile_sample
출력: apps/mobile/assets/sample/ (합성 자료), apps/mobile/assets/dictionaries/ (공통 사전 사본)
"""
from __future__ import annotations

import json
from datetime import date
from pathlib import Path

from backend.contracts import schema_errors
from backend.recommendation import recommend

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "apps/mobile/assets/sample"
DICT_OUT = ROOT / "apps/mobile/assets/dictionaries"
TODAY = date(2026, 10, 17)
GENERATED_AT = "2026-10-17T03:05:00Z"


def load(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def write(name: str, data, out: Path = OUT) -> None:
    (out / name).write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    DICT_OUT.mkdir(parents=True, exist_ok=True)
    notices = [load(p) for p in sorted((ROOT / "fixtures/valid/notice").glob("*.json"))]
    profile = load(ROOT / "fixtures/valid/user_profile/complete.json")
    empty = load(ROOT / "fixtures/valid/user_profile/empty.json")

    personalized = recommend(notices, profile, today=TODAY, generated_at=GENERATED_AT)
    latest = recommend(notices, empty, today=TODAY, generated_at=GENERATED_AT)
    for out in (personalized, latest):
        assert schema_errors("recommendation_list_response", out) == []

    write("notices.json", {n["notice_id"]: n for n in notices})
    write("recommendations_personalized.json", personalized)
    write("recommendations_latest.json", latest)
    for name in ("categories", "majors", "interests", "roles", "universities"):
        write(f"{name}.json", load(ROOT / f"contracts/dictionaries/{name}.json"), DICT_OUT)  # 앱 공통(샘플·실제)
    write("profile.json", profile)
    print(f"notices {len(notices)}, personalized {len(personalized['items'])}, latest {len(latest['items'])}")


if __name__ == "__main__":
    main()
