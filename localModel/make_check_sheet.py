"""새 알림톡 라벨을 '필요한 칸만' 사람이 확인하는 표 (kakao_collect.py 다음 단계).

공지를 두 갈래로 나눈다.
  시험용 (check_test.csv)   무작위 표본. 원문만 보고 빈칸으로 매긴다. 제안을 보여 주지 않는다.
                            제안을 보고 고른 정답으로 규칙·Gemma·모델을 채점하면 그 방법들에 유리해지기 때문이다.
  학습용 (check_train.csv)  나머지. 기계가 맞힐 만한 칸은 미리 채우고, 사람은 빈칸만 채운다.

학습용에서 사람이 채우는 칸 (사람 정답 287건 교차 검증으로 정한 기준, D-033)
  관심사    규칙·Gemma·모델이 모두 같고 모델이 애매하지 않으면 자동 (287건 중 61%, 그중 97%가 사람 정답과 같음).
            나머지는 '관심사_후보'를 보고 채운다.
  카테고리  항상 사람이 고른다. 셋이 같아도 74%만 맞았다(사람의 other를 기계는 academic으로 냄).
            '카테고리_후보'에 세 방법의 답이 있다. 정답이 후보에 없을 때도 있다(32%).
  전체대상  비우면 카테고리로 정한다: admin_notice·other → Y, 교육·공모전·장학 등 신청형 → N.
            extracurricular·event·academic은 사람 정답에서도 갈려서 직접 적는다.

입력  collected/new_arrivals.jsonl (기본), Gemma 라벨 collected/labels_gemma_new.jsonl (없으면 --gemma로 만든다)
사용
  python make_check_sheet.py                 표 만들기 (이미 있으면 채운 칸은 두고 새 공지만 덧붙임)
  python make_check_sheet.py --gemma         Gemma 라벨이 없는 공지에 Ollama로 라벨을 붙인 뒤 표 만들기
  python make_check_sheet.py --merge         두 표 검사 후 collected/labels_new.jsonl
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import random
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(BASE))
sys.path.insert(0, BASE)

from label_agreement import parse_value  # noqa: E402
from make_label_sheet import NONE, load_dict  # noqa: E402
from make_review_set import load_rules, rule_label  # noqa: E402

COLLECTED = os.path.join(BASE, "kakaoTalk_data", "collected")
TEST_RATIO, TEST_MIN, TEST_MAX = 0.3, 20, 60  # 시험용 표본 크기: 30%, 20~60건
TEST_COLUMNS = ["id", "방", "제목", "본문", "정답_관심사", "정답_카테고리", "정답_전체대상", "메모"]
TRAIN_COLUMNS = ["id", "방", "제목", "본문", "관심사_후보", "정답_관심사", "카테고리_후보", "정답_카테고리",
                 "정답_전체대상", "메모", "자동"]
ANSWER = ("정답_관심사", "정답_카테고리", "정답_전체대상", "메모")
FOR_ALL_BY_CATEGORY = {"admin_notice": "Y", "other": "Y"}
ASK_FOR_ALL = {"extracurricular", "event", "academic"}  # 나머지 카테고리는 N


def read_jsonl(path):
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        return {r["id"]: r for r in map(json.loads, filter(str.strip, f))}


def read_sheet(path):
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8-sig") as f:
        return {r["id"]: r for r in csv.DictReader(f)}


def write_sheet(path, columns, rows):
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=columns, restval="")
        w.writeheader()
        w.writerows(rows)


def short_room(room):
    return room.replace("명지전문대학", "").strip()


def fmt_tags(tags):
    return " ".join(sorted(tags)) or NONE


def predictions(notices, gemma_labels, classify):
    """{id: {"규칙", "Gemma", "모델": {"interest_ids", "category"}, "애매": bool}}"""
    interest_rules, category_rules = load_rules()
    out = {}
    for i, n in notices.items():
        m = classify(n["title"], n["text"])
        out[i] = {"규칙": rule_label(n, interest_rules, category_rules),
                  "Gemma": gemma_labels.get(i),
                  "모델": {"interest_ids": m.interest_ids, "category": m.category},
                  "애매": bool(m.unsure)}
    return out


def pick_test(ids, rooms, already, used, seed=0):
    """방별 층화 무작위 표본. 이미 시험용인 공지는 그대로 두고 모자란 만큼만 처음 보는 공지에서 더 뽑는다.

    used: 이미 학습용 표에 있던 공지. 제안을 본 적이 있을 수 있어 시험용으로 옮기지 않는다.
    """
    target = max(TEST_MIN, min(TEST_MAX, round(len(ids) * TEST_RATIO)))
    target = min(target, len(ids))
    chosen = [i for i in ids if i in already]
    fresh = [i for i in ids if i not in already and i not in used]
    rng = random.Random(seed)
    rng.shuffle(fresh)
    fresh.sort(key=lambda i: rooms[i])  # 방 순서로 안정 정렬 → 아래에서 방마다 번갈아 뽑음
    by_room = {}
    for i in fresh:
        by_room.setdefault(rooms[i], []).append(i)
    while len(chosen) < target and any(by_room.values()):
        for room in sorted(by_room):
            if by_room[room] and len(chosen) < target:
                chosen.append(by_room[room].pop(0))
    return set(chosen)


def build(collected=COLLECTED, notices_path=None, classify=None, seed=0):
    notices = read_jsonl(notices_path or os.path.join(collected, "new_arrivals.jsonl"))
    if not notices:
        sys.exit("새 공지가 없습니다. 먼저 kakao_collect.py를 돌리세요.")
    if classify is None:
        from backend.classifier.cascade import classify as cascade_classify
        classify = cascade_classify
    gemma = read_jsonl(os.path.join(collected, "labels_gemma_new.jsonl"))
    preds = predictions(notices, gemma, classify)

    test_path, train_path = os.path.join(collected, "check_test.csv"), os.path.join(collected, "check_train.csv")
    old_test, old_train = read_sheet(test_path), read_sheet(train_path)
    ids = sorted(notices)
    test = pick_test(ids, {i: notices[i]["room"] for i in ids}, set(old_test), set(old_train), seed)
    no_gemma = 0

    test_rows, train_rows = [], []
    for i in ids:
        n, p = notices[i], preds[i]
        base = {"id": i, "방": short_room(n["room"]), "제목": n["title"], "본문": n["text"]}
        if i in test:
            prev = old_test.get(i, {})
            test_rows.append({**base, **{c: prev.get(c, "") for c in ANSWER}})
            continue
        methods = {k: v for k, v in (("규칙", p["규칙"]), ("Gemma", p["Gemma"]), ("모델", p["모델"])) if v}
        no_gemma += p["Gemma"] is None
        tag_sets = {frozenset(v["interest_ids"]) for v in methods.values()}
        auto_interest = len(methods) == 3 and len(tag_sets) == 1 and not p["애매"]
        prev = old_train.get(i, {})
        row = {**base,
               "관심사_후보": " / ".join(f"{k} {fmt_tags(v['interest_ids'])}" for k, v in methods.items()),
               "카테고리_후보": " / ".join(f"{k} {v['category']}" for k, v in methods.items()),
               **{c: prev.get(c, "") for c in ANSWER},
               "자동": "관심사" if auto_interest else ""}
        if auto_interest and not row["정답_관심사"]:
            row["정답_관심사"] = fmt_tags(next(iter(tag_sets)))
        train_rows.append(row)
    # 사람이 채울 칸이 많은 공지부터
    train_rows.sort(key=lambda r: (r["자동"] == "관심사", r["id"]))

    write_sheet(test_path, TEST_COLUMNS, test_rows)
    write_sheet(train_path, TRAIN_COLUMNS, train_rows)
    auto = sum(r["자동"] == "관심사" for r in train_rows)
    ask_all = len(train_rows)  # 카테고리는 전부
    print(f"새 공지 {len(ids)}건 → 시험용 {len(test_rows)}건 (빈칸 3개씩), 학습용 {len(train_rows)}건")
    print(f"학습용에서 사람이 채울 칸: 관심사 {len(train_rows) - auto}칸 (자동 {auto}칸), 카테고리 {ask_all}칸, "
          f"전체대상은 카테고리가 extracurricular·event·academic일 때만")
    if no_gemma:
        print(f"⚠ Gemma 라벨이 없는 학습용 공지 {no_gemma}건은 관심사를 자동으로 채우지 않았습니다 (--gemma로 붙이면 줄어듦)")
    print(f"→ {test_path}\n→ {train_path}")
    return {"test": len(test_rows), "train": len(train_rows), "auto_interest": auto}


def merge(collected=COLLECTED):
    interests = {i for i, _ in load_dict("interests")}
    categories = {i for i, _ in load_dict("categories")}
    errors, out = [], []
    for split, name in (("test", "check_test.csv"), ("train", "check_train.csv")):
        path = os.path.join(collected, name)
        if not os.path.exists(path):
            errors.append(f"{name}: 없음 (먼저 표를 만드세요)")
        rows = read_sheet(path)
        for line_no, (i, r) in enumerate(rows.items(), start=2):
            vals, src = {}, {}
            for field, col in (("관심사", "정답_관심사"), ("카테고리", "정답_카테고리"), ("전체대상", "정답_전체대상")):
                raw = r.get(col, "")
                if field == "전체대상" and not raw.strip() and split == "train":
                    cat = vals.get("카테고리")
                    if cat in ASK_FOR_ALL:
                        errors.append(f"{name} {line_no}행 ({i}) 정답_전체대상: 카테고리가 {cat}이면 직접 적음")
                        continue
                    if cat:
                        vals[field], src[field] = FOR_ALL_BY_CATEGORY.get(cat, "N"), "카테고리 규칙"
                    continue
                v, err = parse_value(field, raw, interests, categories)
                if err:
                    errors.append(f"{name} {line_no}행 ({i}) {col}: {err}")
                    continue
                vals[field] = v
                src[field] = "자동" if field == "관심사" and r.get("자동") == "관심사" else "사람"
            if len(vals) == 3:
                out.append({"id": i, "split": split, "interest_ids": list(vals["관심사"]), "category": vals["카테고리"],
                            "for_all_students": vals["전체대상"] == "Y", "source": src})
    if errors:
        sys.exit("오류:\n" + "\n".join(errors))
    path = os.path.join(collected, "labels_new.jsonl")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for r in sorted(out, key=lambda r: r["id"]):
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    with open(path, "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    n_test = sum(r["split"] == "test" for r in out)
    print(f"labels_new.jsonl {len(out)}건 (시험용 {n_test}, 학습용 {len(out) - n_test}) SHA-256 {sha}")
    return path


def add_gemma_labels(collected=COLLECTED, model="gemma4:12b"):
    """Gemma 라벨이 없는 새 공지에 Ollama로 라벨을 붙여 labels_gemma_new.jsonl에 덧붙인다."""
    from backend.classifier.gemma_tags import chat, validate
    notices = read_jsonl(os.path.join(collected, "new_arrivals.jsonl"))
    path = os.path.join(collected, "labels_gemma_new.jsonl")
    done = read_jsonl(path)
    todo = [i for i in sorted(notices) if i not in done]
    with open(path, "a", encoding="utf-8", newline="\n") as f:
        for k, i in enumerate(todo, 1):
            n = notices[i]
            try:
                g = validate(chat(model, n["title"], n["text"]))
            except Exception as e:  # Ollama 꺼짐 등: 나머지는 다음에
                print(f"Gemma 실패 ({type(e).__name__}), {k - 1}/{len(todo)}건까지 저장")
                return
            f.write(json.dumps({"id": i, "model": model, **g}, ensure_ascii=False) + "\n")
            f.flush()
    print(f"Gemma 라벨 {len(todo)}건 추가")


def main(argv=None):
    ap = argparse.ArgumentParser(description="새 알림톡 라벨 확인 표")
    ap.add_argument("--collected", default=COLLECTED)
    ap.add_argument("--gemma", action="store_true", help="Gemma 라벨이 없는 공지에 Ollama로 라벨을 붙인 뒤 표를 만든다")
    ap.add_argument("--gemma-model", default="gemma4:12b")
    ap.add_argument("--merge", action="store_true", help="두 표를 검사해 labels_new.jsonl을 쓴다")
    args = ap.parse_args(argv)
    if args.merge:
        merge(args.collected)
        return
    if args.gemma:
        add_gemma_labels(args.collected, args.gemma_model)
    build(args.collected)


if __name__ == "__main__":
    main()
