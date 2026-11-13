"""게시판 공고의 조건 추출을 합의된 정답표로 채점한다. 읽기 전용, 표준 라이브러리만.

입력: data/local/gold/board_gold.csv (board_gold_agreement.py --merge 결과), data/local/notices.json
맨 위에 '틀린 지원 가능'(정답 판정이 met이 아닌데 evaluate가 met)을 낸다. 합격 기준은 0건이다.

지표
- 마감일: 정답이 날짜인 칸과 분석 결과 application_deadline.date의 완전 일치.
  정밀도 = 일치 / 분석이 날짜를 낸 칸, 재현율 = 일치 / 정답이 날짜인 칸. 정답이 판단불가인 칸은 뺀다.
  틀린 날짜 = 분석이 날짜를 냈는데 정답과 다른 칸(정답이 없음인 경우 포함).
- 구조 조건: (field, 값) 한 쌍을 한 단위로 센다. 학교·학과·학년·재학상태 따로, 합계도 낸다.
  분석 쪽은 validation_status가 validated인 조건만 센다(판정에 쓰이는 조건). 값이 목록이면 값마다 한 단위.
- 자유 조건: 정답 문구 하나가 '잡혔다'는 것은 분석의 conditions[].evidence 또는 unresolved_conditions[].evidence 중
  하나에 포함될 때다. 비교 전에 공백·문장부호·기호를 떼고(글자·숫자만 남김) 소문자로 바꾼다.
  너무 느슨해지지 않게 두 규칙을 둔다.
  1) 정규화한 정답 문구가 MIN_FREE_LEN(4)자 미만이면 비교하지 않고 놓친 것으로 센다(사유 표시).
  2) 근거 글이 정답 문구의 MAX_EVIDENCE_RATIO(5)배보다 길면 그 근거로는 잡은 것으로 세지 않는다
     (조건을 통째로 긁어 온 긴 글이 무엇이든 포함하는 것을 막는다).
  포함은 정답 문구가 근거 안에 든 한 방향만 본다.
- 판정: 고정 프로필 4개로 backend.recommendation.eligibility.evaluate를 돌려 정답 판정과 3x3 혼동표를 낸다.
  정답 판정(정답표에서 기계적으로)
    1. 누구나 Y이고 자유조건 없음 -> met
    2. 구조 조건이 프로필과 어긋남(그 열에 코드가 있는데 프로필 값이 그중에 없음) -> not_met
    3. 자유조건이 하나라도 있음 -> needs_check
    4. 그 밖(구조 조건이 모두 맞음) -> met
  4번은 누구나 N인데 구조 조건·자유조건이 모두 없는 행도 met으로 만든다. 이런 행은 따로 세어 알린다.

실행: uv run python tools/eval_board_extraction.py [--gold PATH] [--notices PATH] [--json]
"""
from __future__ import annotations

import argparse
import json
import sys
import unicodedata
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # python tools/x.py 로 돌릴 때 필요

from backend.recommendation.eligibility import evaluate  # noqa: E402
from tools.board_gold_common import (  # noqa: E402
    GOLD_DIR, NONE, NOTICES, STRUCT_FIELDS, UNKNOWN, codes_of, free_conditions,
    load_notices, read_sheet, validate_rows,
)

MIN_FREE_LEN = 4
MAX_EVIDENCE_RATIO = 5
STATUSES = ["met", "needs_check", "not_met"]

# 고정 프로필(사전 코드). 졸업 프로필의 학년은 졸업 시점 학년을 3으로 둔다(경영·컴공 프로필과 학과가 겹치지 않게 컴공).
PROFILES = {
    "경영학과 2학년 휴학": {"university_id": "mjc", "major_id": "mjc.business_administration", "grade": 2, "enrollment_status": "on_leave"},
    "컴퓨터공학과 2학년 재학": {"university_id": "mjc", "major_id": "mjc.computer_engineering", "grade": 2, "enrollment_status": "enrolled"},
    "졸업": {"university_id": "mjc", "major_id": "mjc.computer_engineering", "grade": 3, "enrollment_status": "graduated"},
    "1학년 재학": {"university_id": "mjc", "major_id": "mjc.computer_engineering", "grade": 1, "enrollment_status": "enrolled"},
}


def normalize(text: str) -> str:
    kept = [ch for ch in text if unicodedata.category(ch)[0] in ("L", "N", "M")]
    return "".join(kept).lower()


def _ratio(k: int, n: int) -> float | None:
    return k / n if n else None


def pred_units(eligibility: dict) -> set[tuple[str, str]]:
    units = set()
    for cond in eligibility["conditions"]:
        if cond["validation_status"] != "validated":
            continue
        values = cond["value"] if isinstance(cond["value"], list) else [cond["value"]]
        units.update((cond["field"], str(v)) for v in values)
    return units


def gold_units(row: dict) -> set[tuple[str, str]]:
    return {(field, code) for col, field in STRUCT_FIELDS.items() for code in codes_of(row[col])}


def score_deadlines(rows: list[dict], notices: dict) -> dict:
    tp = pred_n = gold_n = 0
    wrong, missed = [], []
    for r in rows:
        gold = r["마감일"].strip()
        if gold == UNKNOWN:
            continue
        dl = notices[r["notice_id"]]["application_deadline"]
        pred = dl["date"] if dl else None
        gold_date = None if gold == NONE else gold
        pred_n += pred is not None
        gold_n += gold_date is not None
        if pred is not None and pred == gold_date:
            tp += 1
        elif pred is not None:
            wrong.append({"notice_id": r["notice_id"], "정답": gold, "분석": pred})
        elif gold_date is not None:
            missed.append({"notice_id": r["notice_id"], "정답": gold})
    return {
        "정밀도": _ratio(tp, pred_n), "재현율": _ratio(tp, gold_n),
        "일치": tp, "분석이_낸_날짜": pred_n, "정답_날짜": gold_n,
        "틀린_날짜_건수": len(wrong), "틀린_날짜": wrong, "놓친_날짜_건수": len(missed), "놓친_날짜": missed,
    }


def score_structure(rows: list[dict], notices: dict) -> dict:
    count = {f: {"tp": 0, "fp": 0, "fn": 0} for f in STRUCT_FIELDS.values()}
    for r in rows:
        pred = pred_units(notices[r["notice_id"]]["eligibility"])
        gold = gold_units(r)
        for field in count:
            p = {u for u in pred if u[0] == field}
            g = {u for u in gold if u[0] == field}
            count[field]["tp"] += len(p & g)
            count[field]["fp"] += len(p - g)
            count[field]["fn"] += len(g - p)
    out = {}
    names = {v: k for k, v in STRUCT_FIELDS.items()}
    total = {"tp": 0, "fp": 0, "fn": 0}
    for field, c in count.items():
        for k in total:
            total[k] += c[k]
        out[names[field]] = _prf(c)
    out["합계"] = _prf(total)
    return out


def _prf(c: dict) -> dict:
    return {**c, "정밀도": _ratio(c["tp"], c["tp"] + c["fp"]), "재현율": _ratio(c["tp"], c["tp"] + c["fn"])}


def caught(phrase: str, evidences: list[str]) -> tuple[bool, str | None]:
    """정답 문구가 잡혔는지와, 못 잡았을 때 사유."""
    g = normalize(phrase)
    if len(g) < MIN_FREE_LEN:
        return False, f"너무 짧아 비교하지 않음(정규화 {len(g)}자 < {MIN_FREE_LEN})"
    for ev in evidences:
        e = normalize(ev)
        if g in e and len(e) <= MAX_EVIDENCE_RATIO * len(g):
            return True, None
    return False, None


def score_free(rows: list[dict], notices: dict) -> dict:
    total = hit = 0
    missed = []
    for r in rows:
        phrases = free_conditions(r["자유조건"])
        if not phrases:
            continue
        el = notices[r["notice_id"]]["eligibility"]
        evidences = [c["evidence"] for c in el["conditions"]] + [u["evidence"] for u in el["unresolved_conditions"]]
        for ph in phrases:
            total += 1
            ok, why = caught(ph, evidences)
            hit += ok
            if not ok:
                missed.append({"notice_id": r["notice_id"], "문구": ph, **({"사유": why} if why else {})})
    return {"포착률": _ratio(hit, total), "포착": hit, "정답_문구": total, "놓친_문구": missed}


def gold_status(row: dict, profile: dict) -> str:
    free = free_conditions(row["자유조건"])
    if row["누구나"].strip() == "Y" and not free:
        return "met"
    for col, field in STRUCT_FIELDS.items():
        codes = codes_of(row[col])
        if codes and str(profile[field]) not in codes:
            return "not_met"
    return "needs_check" if free else "met"


def score_judgement(rows: list[dict], notices: dict) -> dict:
    tables = {name: {g: {p: 0 for p in STATUSES} for g in STATUSES} for name in PROFILES}
    wrong_met = []
    for r in rows:
        el = notices[r["notice_id"]]["eligibility"]
        for name, profile in PROFILES.items():
            gold = gold_status(r, profile)
            pred, _ = evaluate(el, profile)
            tables[name][gold][pred] += 1
            if pred == "met" and gold != "met":
                wrong_met.append({"notice_id": r["notice_id"], "프로필": name, "정답": gold, "제목": notices[r["notice_id"]]["title"]})
    total = {g: {p: sum(t[g][p] for t in tables.values()) for p in STATUSES} for g in STATUSES}
    empty_n = sum(
        1 for r in rows
        if r["누구나"].strip() == "N" and not free_conditions(r["자유조건"]) and not any(codes_of(r[c]) for c in STRUCT_FIELDS)
    )
    return {"틀린_지원_가능_건수": len(wrong_met), "틀린_지원_가능": wrong_met, "혼동표_합계": total,
            "혼동표_프로필별": tables, "누구나N_조건없음_행": empty_n}


def evaluate_all(gold_rows: list[dict], notices: dict) -> dict:
    present = [r for r in gold_rows if r["notice_id"] in notices]
    absent = [r["notice_id"] for r in gold_rows if r["notice_id"] not in notices]
    return {
        "채점_건수": len(present), "notices에_없는_공고": absent,
        "판정": score_judgement(present, notices),
        "마감일": score_deadlines(present, notices),
        "구조_조건": score_structure(present, notices),
        "자유_조건": score_free(present, notices),
    }


def _f(x: float | None) -> str:
    return "-" if x is None else f"{x:.3f}"


def render(res: dict) -> str:
    j, d, s, fr = res["판정"], res["마감일"], res["구조_조건"], res["자유_조건"]
    out = [f"틀린 지원 가능: {j['틀린_지원_가능_건수']}건 (합격 기준 0건)"]
    out += [f"  {w['notice_id']} [{w['프로필']}] 정답 {w['정답']}: {w['제목']}" for w in j["틀린_지원_가능"]]
    out.append(f"\n채점 {res['채점_건수']}건" + (f", notices.json에 없어 뺀 공고 {len(res['notices에_없는_공고'])}건" if res["notices에_없는_공고"] else ""))
    out.append(f"\n[마감일] 정밀도 {_f(d['정밀도'])} ({d['일치']}/{d['분석이_낸_날짜']}), 재현율 {_f(d['재현율'])} ({d['일치']}/{d['정답_날짜']})")
    out.append(f"  틀린 날짜 {d['틀린_날짜_건수']}건, 놓친 날짜 {d['놓친_날짜_건수']}건")
    out += [f"  틀림 {w['notice_id']}: 정답 {w['정답']} / 분석 {w['분석']}" for w in d["틀린_날짜"]]
    out.append("\n[구조 조건] 조건 단위")
    for name, c in s.items():
        out.append(f"  {name}: 정밀도 {_f(c['정밀도'])} 재현율 {_f(c['재현율'])} (tp {c['tp']}, fp {c['fp']}, fn {c['fn']})")
    out.append(f"\n[자유 조건] 포착률 {_f(fr['포착률'])} ({fr['포착']}/{fr['정답_문구']}), 놓친 {len(fr['놓친_문구'])}건")
    out += [f"  {m['notice_id']}: {m['문구']}" + (f"  ({m['사유']})" if "사유" in m else "") for m in fr["놓친_문구"]]
    out.append("\n[판정] 행 정답, 열 evaluate 결과 (프로필 4개 합계)")
    out.append("  정답\\분석   " + "  ".join(f"{p:>11}" for p in STATUSES))
    for g in STATUSES:
        out.append(f"  {g:<11} " + "  ".join(f"{j['혼동표_합계'][g][p]:>11}" for p in STATUSES))
    if j["누구나N_조건없음_행"]:
        out.append(f"  주의: 누구나 N인데 조건이 전혀 없는 정답 행 {j['누구나N_조건없음_행']}건(규칙 4로 met)")
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--gold", type=Path, default=GOLD_DIR / "board_gold.csv")
    ap.add_argument("--notices", type=Path, default=NOTICES)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    rows = read_sheet(args.gold)
    errors = validate_rows(rows, "정답표")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    res = evaluate_all(rows, load_notices(args.notices))
    if args.json:
        print(json.dumps(res, ensure_ascii=False, indent=2))
    else:
        print(render(res))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
