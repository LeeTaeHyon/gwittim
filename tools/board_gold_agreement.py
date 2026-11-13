"""게시판 정답표 두 벌(A, B)의 일치도를 내고 합의표를 만든다.

입력: 채운 data/local/gold/board_sheet_A.csv, board_sheet_B.csv
검사: 마감일 형식, 누구나 Y/N, 학교·학과·학년·재학상태의 사전 코드, 빈 칸 -> 행 번호와 함께 오류로 내고 멈춘다.

출력
- 마감일·누구나 일치율(건수/전체)
- 참고로 학교·학과·학년·재학상태(코드 집합 일치)와 자유조건(줄 집합 일치) 일치율
- 갈린 칸 목록 board_disagreements.csv: notice_id, 제목, 항목(마감일 또는 누구나), A, B, 합의(빈 칸).
  이미 있으면 덮어쓰지 않는다(채운 합의를 지키기 위해).

--merge: 갈린 칸의 합의가 모두 찼을 때만 board_gold.csv를 쓴다. 이미 있으면 멈춘다.
- 합의 대상은 마감일·누구나 두 칸뿐이다. 갈렸으면 합의 값, 같았으면 그 값을 쓴다.
- 합의 대상이 아닌 칸(학교, 학과, 학년, 재학상태, 자유조건, 메모)은 A 값을 그대로 쓴다.
  이 칸들은 두 사람이 합의하지 않았으므로 채점 결과를 읽을 때 한 사람의 정답임을 감안한다.
- 끝에 board_gold.csv의 SHA-256을 출력한다.

실행: uv run python tools/board_gold_agreement.py [--a PATH] [--b PATH] [--out-dir DIR] [--merge]
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # python tools/x.py 로 돌릴 때 필요

from tools.board_gold_common import (  # noqa: E402
    GOLD_DIR, STRUCT_FIELDS, check_deadline, check_everyone, free_conditions,
    read_sheet, validate_rows, write_sheet, COLUMNS,
)

AGREED = ("마감일", "누구나")
DIS_COLUMNS = ["notice_id", "제목", "항목", "A", "B", "합의"]


def _rate(k: int, n: int) -> str:
    return f"{k}/{n} ({k / n:.1%})" if n else "0/0"


def disagreements(a_rows: list[dict], b_rows: list[dict]) -> list[dict]:
    b_by = {r["notice_id"]: r for r in b_rows}
    out = []
    for ra in a_rows:
        rb = b_by[ra["notice_id"]]
        for col in AGREED:
            va, vb = ra[col].strip(), rb[col].strip()
            if va != vb:
                out.append({"notice_id": ra["notice_id"], "제목": ra["제목"], "항목": col, "A": va, "B": vb, "합의": ""})
    return out


def _load(path: Path, label: str) -> list[dict]:
    rows = read_sheet(path)
    errors = validate_rows(rows, label)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        raise SystemExit(f"{label} 표 오류 {len(errors)}건. 고친 뒤 다시 실행")
    return rows


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--a", type=Path, default=GOLD_DIR / "board_sheet_A.csv")
    ap.add_argument("--b", type=Path, default=GOLD_DIR / "board_sheet_B.csv")
    ap.add_argument("--out-dir", type=Path, default=GOLD_DIR)
    ap.add_argument("--merge", action="store_true")
    args = ap.parse_args(argv)

    a_rows, b_rows = _load(args.a, "A"), _load(args.b, "B")
    ids_a, ids_b = {r["notice_id"] for r in a_rows}, {r["notice_id"] for r in b_rows}
    if ids_a != ids_b:
        print(f"A와 B의 공고가 다름: A에만 {sorted(ids_a - ids_b)[:5]}, B에만 {sorted(ids_b - ids_a)[:5]}", file=sys.stderr)
        return 1
    b_by = {r["notice_id"]: r for r in b_rows}
    n = len(a_rows)

    for col in AGREED:
        k = sum(1 for r in a_rows if r[col].strip() == b_by[r["notice_id"]][col].strip())
        print(f"{col} 일치: {_rate(k, n)}")
    for col in STRUCT_FIELDS:
        k = sum(1 for r in a_rows if set(r[col].split()) == set(b_by[r["notice_id"]][col].split()))
        print(f"(참고) {col} 일치: {_rate(k, n)}")
    k = sum(1 for r in a_rows if set(free_conditions(r["자유조건"])) == set(free_conditions(b_by[r["notice_id"]]["자유조건"])))
    print(f"(참고) 자유조건 줄 집합 일치: {_rate(k, n)}")

    diffs = disagreements(a_rows, b_rows)
    dis_path = args.out_dir / "board_disagreements.csv"
    gold_path = args.out_dir / "board_gold.csv"
    if not args.merge:
        if dis_path.exists():
            print(f"갈린 칸 {len(diffs)}건. {dis_path} 가 이미 있어 다시 쓰지 않음")
        else:
            args.out_dir.mkdir(parents=True, exist_ok=True)
            write_sheet(dis_path, diffs, DIS_COLUMNS)
            print(f"갈린 칸 {len(diffs)}건 -> {dis_path}")
        return 0

    # --merge
    if gold_path.exists():
        print(f"{gold_path} 가 이미 있어 멈춤(덮어쓰지 않음)", file=sys.stderr)
        return 1
    if not dis_path.exists():
        print(f"{dis_path} 가 없음. --merge 없이 먼저 실행", file=sys.stderr)
        return 1
    with dis_path.open(encoding="utf-8-sig", newline="") as f:
        filled = list(csv.DictReader(f))
    expected = {(d["notice_id"], d["항목"]) for d in diffs}
    got = {(d["notice_id"], d["항목"]) for d in filled}
    if expected != got:
        print("갈린 칸 목록이 현재 A·B 표와 맞지 않음. 표를 고쳤다면 목록을 지우고 다시 만든다", file=sys.stderr)
        return 1
    final: dict[tuple[str, str], str] = {}
    errors = []
    for i, d in enumerate(filled, start=2):
        value = d["합의"].strip()
        checker = check_deadline if d["항목"] == "마감일" else check_everyone
        problem = "합의가 빈 칸" if not value else checker(value)
        if problem:
            errors.append(f"합의 표 {i}행 ({d['notice_id']} {d['항목']}): {problem}")
        final[(d["notice_id"], d["항목"])] = value
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1

    merged = []
    for r in a_rows:
        row = {c: r[c] for c in COLUMNS}
        for col in AGREED:
            row[col] = final.get((r["notice_id"], col), r[col].strip())
        merged.append(row)
    write_sheet(gold_path, merged)
    digest = hashlib.sha256(gold_path.read_bytes()).hexdigest()
    print(f"합의표 {len(merged)}건 -> {gold_path}")
    print(f"SHA-256: {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
