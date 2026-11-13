"""두 작업자의 라벨 표 일치도와 합의 (docs/stage2-work-spec.md W2).

입력 (--data-dir, 기본 kakaoTalk_data/processed): 채운 label_sheet_A.csv, label_sheet_B.csv
검사: 사전에 없는 코드, 빈 칸, 두 표의 공지 목록 차이 → 표 이름·행 번호와 함께 오류를 모두 내고 멈춘다.
출력
  화면                       종류 κ, 관심사 꼬리표별 κ(양쪽 합쳐 5건 미만인 꼬리표는 건수만), 전체 대상 κ
  label_disagreements.csv    갈린 칸 목록 (id, 항목, 제목, A, B, 합의). '합의' 칸은 둘이 정해 채운다.
                             다시 돌려도 A·B 답이 그대로인 행의 '합의'는 남긴다.
  --merge                    합의 칸이 모두 찼을 때만 labels_human.jsonl을 쓴다.
                             한 줄에 id, interest_ids, category, for_all_students, a, b(합의 전 두 사람의 답)
끝에 labels_human.jsonl의 SHA-256을 출력한다. 합의가 끝나면 이 값과 날짜를 docs/decisions.md에 적는다.

사용 (표준 라이브러리만)
  python label_agreement.py
  python label_agreement.py --merge
"""
import argparse
import csv
import hashlib
import json
import os
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(BASE))

from make_label_sheet import DATA, NONE, load_dict, sheet_path  # noqa: E402
from tools.evalstats import cohen_kappa  # noqa: E402

FIELDS = {"관심사": "정답_관심사", "카테고리": "정답_카테고리", "전체대상": "정답_전체대상"}
MIN_TAG_COUNT = 5  # 양쪽 합쳐 이보다 적게 붙은 꼬리표는 κ가 불안정해 건수만 낸다
KAPPA_OK = 0.6
DISAGREE_COLUMNS = ["id", "항목", "제목", "A", "B", "합의"]


class LabelError(Exception):
    pass


def parse_value(field, raw, interests, categories):
    """칸 값 → 정규화한 값. 잘못된 값이면 오류 문구."""
    v = raw.strip()
    if not v:
        return None, "빈 칸"
    if field == "관심사":
        tags = v.split()
        if tags == [NONE]:
            return (), None
        bad = [t for t in tags if t not in interests]
        if bad:
            return None, f"사전에 없는 관심사 {bad} (꼬리표가 없으면 '{NONE}' 하나만)"
        return tuple(sorted(set(tags))), None
    if field == "카테고리":
        return (v, None) if v in categories else (None, f"사전에 없는 카테고리 '{v}'")
    return (v, None) if v in ("Y", "N") else (None, f"전체대상은 Y 또는 N ('{v}')")


def fmt(field, v):
    return (" ".join(v) or NONE) if field == "관심사" else v


def read_sheet(path, interests, categories, errors):
    """{id: {"제목", "관심사", "카테고리", "전체대상"}}. 오류는 errors에 모은다."""
    name = os.path.basename(path)
    if not os.path.exists(path):
        errors.append(f"{name}: 파일 없음")
        return {}
    out = {}
    with open(path, encoding="utf-8-sig") as f:
        for line_no, row in enumerate(csv.DictReader(f), start=2):  # 1행은 머리글
            if row["id"] in out:
                errors.append(f"{name} {line_no}행: id {row['id']} 중복")
                continue
            rec = {"제목": row["제목"]}
            for field, col in FIELDS.items():
                v, err = parse_value(field, row.get(col) or "", interests, categories)
                if err:
                    errors.append(f"{name} {line_no}행 ({row['id']}) {col}: {err}")
                rec[field] = v
            out[row["id"]] = rec
    return out


def load_both(data_dir):
    interests = {i for i, _ in load_dict("interests")}
    categories = {i for i, _ in load_dict("categories")}
    errors = []
    a = read_sheet(sheet_path(data_dir, "A"), interests, categories, errors)
    b = read_sheet(sheet_path(data_dir, "B"), interests, categories, errors)
    if a and b and set(a) != set(b):
        errors.append(f"두 표의 공지 목록이 다름: A에만 {sorted(set(a) - set(b))}, B에만 {sorted(set(b) - set(a))}")
    if errors:
        raise LabelError("\n".join(errors))
    return a, b, interests, categories


def agreement(a, b, interests):
    ids = sorted(a)
    report = {"n": len(ids), "category_kappa": cohen_kappa([a[i]["카테고리"] for i in ids], [b[i]["카테고리"] for i in ids]),
              "for_all_kappa": cohen_kappa([a[i]["전체대상"] for i in ids], [b[i]["전체대상"] for i in ids]),
              "interest_exact": sum(a[i]["관심사"] == b[i]["관심사"] for i in ids) / len(ids), "tags": {}}
    for t in sorted(interests):
        xa = [t in a[i]["관심사"] for i in ids]
        xb = [t in b[i]["관심사"] for i in ids]
        count = sum(xa) + sum(xb)
        report["tags"][t] = {"A": sum(xa), "B": sum(xb),
                             "kappa": cohen_kappa(xa, xb) if count >= MIN_TAG_COUNT else None}
    return report


def print_agreement(r):
    flag = lambda k: "" if k >= KAPPA_OK else f"  ← {KAPPA_OK} 미만: 정의 보충 후 다시 매김"
    print(f"공지 {r['n']}건")
    print(f"종류 κ {r['category_kappa']:.3f}{flag(r['category_kappa'])}")
    print(f"전체 대상 κ {r['for_all_kappa']:.3f}{flag(r['for_all_kappa'])}")
    print(f"관심사 묶음 완전 일치 {r['interest_exact']:.1%}")
    print("관심사 꼬리표별 (A 건수 / B 건수 / κ)")
    for t, s in r["tags"].items():
        if s["A"] + s["B"] == 0:
            continue
        k = "건수 적음" if s["kappa"] is None else f"{s['kappa']:.3f}{flag(s['kappa'])}"
        print(f"  {t:26} {s['A']:>3} / {s['B']:>3} / {k}")


def write_disagreements(data_dir, a, b):
    path = os.path.join(data_dir, "label_disagreements.csv")
    kept = {}
    if os.path.exists(path):  # 이미 적은 합의는 A·B 답이 그대로일 때만 남긴다
        with open(path, encoding="utf-8-sig") as f:
            kept = {(r["id"], r["항목"], r["A"], r["B"]): r["합의"] for r in csv.DictReader(f)}
    rows = []
    for i in sorted(a):
        for field in FIELDS:
            if a[i][field] != b[i][field]:
                va, vb = fmt(field, a[i][field]), fmt(field, b[i][field])
                rows.append({"id": i, "항목": field, "제목": a[i]["제목"], "A": va, "B": vb,
                             "합의": kept.get((i, field, va, vb), "")})
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=DISAGREE_COLUMNS)
        w.writeheader()
        w.writerows(rows)
    return path, rows


def merge(data_dir, a, b, rows, interests, categories):
    errors, decided = [], {}
    for line_no, r in enumerate(rows, start=2):
        if not r["합의"].strip():
            errors.append(f"label_disagreements.csv {line_no}행 ({r['id']} {r['항목']}): 합의 칸이 비어 있음")
            continue
        v, err = parse_value(r["항목"], r["합의"], interests, categories)
        if err:
            errors.append(f"label_disagreements.csv {line_no}행 ({r['id']} {r['항목']}): {err}")
        decided[(r["id"], r["항목"])] = v
    if errors:
        raise LabelError("\n".join(errors))

    def answer(rec):
        return {"interest_ids": list(rec["관심사"]), "category": rec["카테고리"], "for_all_students": rec["전체대상"] == "Y"}

    path = os.path.join(data_dir, "labels_human.jsonl")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for i in sorted(a):
            final = {field: decided.get((i, field), a[i][field]) for field in FIELDS}
            line = {"id": i, **answer(final), "a": answer(a[i]), "b": answer(b[i])}
            f.write(json.dumps(line, ensure_ascii=False) + "\n")
    return path


def main(argv=None):
    ap = argparse.ArgumentParser(description="라벨 표 A·B 일치도와 합의")
    ap.add_argument("--data-dir", default=DATA)
    ap.add_argument("--merge", action="store_true", help="합의 칸이 모두 찼으면 labels_human.jsonl을 쓴다")
    args = ap.parse_args(argv)
    try:
        a, b, interests, categories = load_both(args.data_dir)
        print_agreement(agreement(a, b, interests))
        path, rows = write_disagreements(args.data_dir, a, b)
        print(f"\n갈린 칸 {len(rows)}개 → {path}")
        if args.merge:
            merge(args.data_dir, a, b, rows, interests, categories)
    except LabelError as e:
        sys.exit(f"오류:\n{e}")
    human = os.path.join(args.data_dir, "labels_human.jsonl")
    if os.path.exists(human):
        with open(human, "rb") as f:
            print(f"labels_human.jsonl SHA-256 {hashlib.sha256(f.read()).hexdigest()}")


if __name__ == "__main__":
    main()
