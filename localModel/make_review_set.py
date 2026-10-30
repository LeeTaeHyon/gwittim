"""규칙 라벨과 Gemma 라벨을 비교하고, 사람이 검수할 시험 세트(review_set.csv)를 뽑는다.

입력: kakaoTalk_data/processed/notices.jsonl, labels_gemma.jsonl
출력: kakaoTalk_data/processed/labels_rule.jsonl, review_set.csv
  review_set.csv의 '정답_관심사'·'정답_카테고리'·'정답_전체대상' 칸을 사람이 채운다.
  여기 뽑힌 공지는 시험용이라 학습에 쓰지 않는다.
  다시 실행해도 이미 채운 정답 행은 (공지 목록에 남아 있으면) 그대로 유지하고 나머지만 새로 뽑는다.
"""
import collections
import csv
import json
import os
import random
import re

BASE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BASE)
PROC = os.path.join(BASE, "kakaoTalk_data", "processed")
REVIEW_SIZE = 50
REVIEW_PATH = os.path.join(PROC, "review_set.csv")
ANSWER_COLS = ["정답_관심사", "정답_카테고리", "정답_전체대상", "메모"]


def load_rules():
    # backend.analysis 패키지는 jsonschema 등을 불러오므로 규칙 정의 부분만 읽어 온다
    src = open(os.path.join(ROOT, "backend", "analysis", "rules.py"), encoding="utf-8").read()
    ns = {"re": re}
    exec(src[src.index("CATEGORY_RULES = [") : src.index("ROLE_RULES = {")], ns)
    return ns["INTEREST_RULES"], ns["CATEGORY_RULES"]


def rule_label(n, interest_rules, category_rules):
    category = "other"
    for target in (n["title"], n["text"]):
        hit = next((code for code, p in category_rules if re.search(p, target)), None)
        if hit:
            category = hit
            break
    tag_text = n["title"] + "\n" + n["text"]
    return {"interest_ids": [k for k, p in interest_rules.items() if re.search(p, tag_text)], "category": category}


def read_jsonl(name):
    with open(os.path.join(PROC, name), encoding="utf-8") as f:
        return [json.loads(l) for l in f]


def load_answers():
    # 이전 review_set.csv에서 사람이 하나라도 채운 행: {id: [정답 칸 값들]}
    if not os.path.exists(REVIEW_PATH):
        return {}
    with open(REVIEW_PATH, encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    return {r["id"]: [r.get(c, "") for c in ANSWER_COLS] for r in rows if any(r.get(c, "").strip() for c in ANSWER_COLS[:3])}


def main():
    interest_rules, category_rules = load_rules()
    notices = read_jsonl("notices.jsonl")
    gemma = {x["id"]: x for x in read_jsonl("labels_gemma.jsonl")}
    rule = {n["id"]: rule_label(n, interest_rules, category_rules) for n in notices}
    with open(os.path.join(PROC, "labels_rule.jsonl"), "w", encoding="utf-8") as f:
        for i, x in rule.items():
            f.write(json.dumps({"id": i, **x}, ensure_ascii=False) + "\n")

    ids = [n["id"] for n in notices if n["id"] in gemma]
    print(f"공지 {len(notices)}건, Gemma 라벨 {len(ids)}건")
    for name, labels in (("규칙", rule), ("Gemma", gemma)):
        tags = collections.Counter(t for i in ids for t in labels[i]["interest_ids"])
        empty = sum(1 for i in ids if not labels[i]["interest_ids"])
        cats = collections.Counter(labels[i]["category"] for i in ids)
        print(f"\n[{name}] 관심사 0개 {empty}건 ({empty / len(ids):.0%})")
        print("  관심사:", tags.most_common())
        print("  카테고리:", cats.most_common())
    print("\nGemma 전체 학생 대상:", sum(gemma[i]["for_all_students"] for i in ids), "건")
    same_tags = sum(set(rule[i]["interest_ids"]) == set(gemma[i]["interest_ids"]) for i in ids)
    same_cat = sum(rule[i]["category"] == gemma[i]["category"] for i in ids)
    print(f"규칙·Gemma 일치: 관심사 {same_tags}/{len(ids)}, 카테고리 {same_cat}/{len(ids)}")

    # 시험 세트: 관심사 판단이 갈린 공지와 일치한 공지를 반씩. 이미 채운 행은 먼저 넣는다
    answers = load_answers()
    dropped = [i for i in answers if i not in rule]
    if dropped:
        print(f"\n공지 목록에서 빠져 시험 세트에서 제외: {dropped}")
    rng = random.Random(0)
    differ = [i for i in ids if set(rule[i]["interest_ids"]) != set(gemma[i]["interest_ids"])]
    agree = [i for i in ids if i not in set(differ)]
    half = REVIEW_SIZE // 2
    picked = [i for i in ids if i in answers]
    for pool, quota in ((differ, half), (agree, REVIEW_SIZE - half)):
        rest = [i for i in pool if i not in picked]
        need = quota - sum(1 for i in picked if i in pool)
        picked += rng.sample(rest, max(0, min(need, len(rest))))
    by_id = {n["id"]: n for n in notices}
    with open(REVIEW_PATH, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["id", "방", "제목", "본문(앞부분)", "규칙_관심사", "Gemma_관심사", "Gemma_카테고리", "Gemma_전체대상", "Gemma_근거",
                    "정답_관심사", "정답_카테고리", "정답_전체대상", "메모"])
        for i in sorted(picked):
            n, g = by_id[i], gemma[i]
            w.writerow([i, n["room"].replace("명지전문대학 ", ""), n["title"], n["text"][:500], " ".join(rule[i]["interest_ids"]),
                        " ".join(g["interest_ids"]), g["category"], "Y" if g["for_all_students"] else "N", g["reason"],
                        *answers.get(i, [""] * len(ANSWER_COLS))])
    n_differ = sum(1 for i in picked if i in set(differ))
    print(f"\n시험 세트 {len(picked)}건 (판단 갈림 {n_differ}건, 기존 정답 유지 {len(picked) - len(set(picked) - set(answers))}건) → review_set.csv")


if __name__ == "__main__":
    main()
