"""게시판 정답표 도구 공용 부분 (열 이름, 사전 코드, 칸 검사).

make_board_gold_sheet.py, board_gold_agreement.py, eval_board_extraction.py가 함께 쓴다.
정답표는 data/local/gold/ 에만 둔다(git 제외).
"""
from __future__ import annotations

import csv
import json
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

NOTICES = ROOT / "data/local/notices.json"
GOLD_DIR = ROOT / "data/local/gold"
DICT_DIR = ROOT / "contracts/dictionaries"

COLUMNS = [
    "notice_id", "게시판", "제목", "source_url",
    "마감일", "학교", "학과", "학년", "재학상태", "자유조건", "누구나", "메모",
]
ANSWER_COLUMNS = COLUMNS[4:]
# 게시판 출처 id -> 표에 적는 이름
BOARDS = {
    "mjc_www_notice": "공지",
    "mjc_www_job": "채용",
    "mjc_www_scholarship": "장학",
    "mjc_www_work": "근로",
}
# 정답표 열 -> Notice.eligibility 조건 field
STRUCT_FIELDS = {
    "학교": "university_id",
    "학과": "major_id",
    "학년": "grade",
    "재학상태": "enrollment_status",
}
NONE = "없음"
UNKNOWN = "판단불가"
GRADES = ["1", "2", "3", "4"]
ENROLLMENT = ["enrolled", "on_leave", "graduated"]


def load_notices(path: Path) -> dict:
    with Path(path).open(encoding="utf-8") as f:
        return json.load(f)


def dictionary_codes() -> dict[str, list[str]]:
    """열 이름 -> 허용 코드 목록."""

    def ids(name: str) -> list[str]:
        with (DICT_DIR / f"{name}.json").open(encoding="utf-8") as f:
            return [item["id"] for item in json.load(f)["items"]]

    return {
        "학교": ids("universities"),
        "학과": ids("majors"),
        "학년": list(GRADES),
        "재학상태": list(ENROLLMENT),
    }


def major_names() -> dict[str, str]:
    with (DICT_DIR / "majors.json").open(encoding="utf-8") as f:
        return {m["id"]: m["name_ko"] for m in json.load(f)["items"]}


def read_sheet(path: Path) -> list[dict]:
    with Path(path).open(encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        missing = [c for c in COLUMNS if c not in (reader.fieldnames or [])]
        if missing:
            raise SystemExit(f"{path}: 없는 열 {missing}")
        return list(reader)


def write_sheet(path: Path, rows: list[dict], columns: list[str] = COLUMNS) -> None:
    with Path(path).open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)


def valid_date(text: str) -> bool:
    try:
        return len(text) == 10 and date.fromisoformat(text).isoformat() == text
    except ValueError:
        return False


def check_deadline(text: str) -> str | None:
    """마감일 칸 오류 문구. 올바르면 None."""
    text = (text or "").strip()
    if not text:
        return "마감일이 빈 칸"
    if text in (NONE, UNKNOWN) or valid_date(text):
        return None
    return f"마감일 형식 오류: {text!r}"


def check_everyone(text: str) -> str | None:
    text = (text or "").strip()
    if not text:
        return "누구나가 빈 칸"
    if text not in ("Y", "N"):
        return f"누구나는 Y 또는 N: {text!r}"
    return None


def codes_of(text: str) -> list[str]:
    """구조 조건 칸의 코드 목록. 없음·빈 칸은 빈 목록."""
    tokens = (text or "").split()
    return [] if tokens == [NONE] else tokens


def check_codes(column: str, text: str, allowed: list[str]) -> str | None:
    tokens = (text or "").split()
    if not tokens:
        return f"{column}가 빈 칸"
    if NONE in tokens and len(tokens) > 1:
        return f"{column}: '없음'과 코드를 함께 쓸 수 없음"
    bad = [t for t in tokens if t != NONE and t not in allowed]
    if bad:
        return f"{column}: 사전에 없는 코드 {bad}"
    return None


def free_conditions(text: str) -> list[str]:
    """자유조건 칸 -> 한 줄에 하나. 빈 줄과 '없음' 줄은 버린다."""
    lines = [ln.strip() for ln in (text or "").splitlines()]
    return [ln for ln in lines if ln and ln != NONE]


def validate_rows(rows: list[dict], label: str) -> list[str]:
    """정답표 행 검사. 오류 문구 목록(행 번호는 CSV 줄 기준, 머리글이 1행)."""
    allowed = dictionary_codes()
    errors: list[str] = []
    seen: set[str] = set()
    for i, row in enumerate(rows, start=2):
        nid = row.get("notice_id", "")
        found = [check_deadline(row.get("마감일", "")), check_everyone(row.get("누구나", ""))]
        found += [check_codes(c, row.get(c, ""), allowed[c]) for c in STRUCT_FIELDS]
        if nid in seen:
            found.append("notice_id 중복")
        seen.add(nid)
        errors += [f"{label} {i}행 ({nid}): {e}" for e in found if e]
    return errors
