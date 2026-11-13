"""알림톡 분류 현재 수치 재현 (docs/stage2-work-spec.md W1). 읽기만 하고 파일을 쓰지 않는다.

입력 (--data-dir, 기본 localModel/kakaoTalk_data/processed, git 제외)
  notices.jsonl, labels_gemma.jsonl, labels_rule.jsonl, review_set.csv
자체 모델은 backend/classifier의 표준 라이브러리 추론으로 예측한다 (TensorFlow 불필요).

채점 대상은 train_keras.load_test_answers와 같은 규칙: review_set.csv에서 정답 칸이 찬 행 중 notices.jsonl에 있는 것.
관심사 채점(tag_scores)도 train_keras.tag_scores와 같은 정의다 (꼬리표 단위 미시 F1, 채점 꼬리표 밖 코드는 양쪽에서 무시).

사용
  uv run python tools/eval_kakao_classifier.py
  uv run python tools/eval_kakao_classifier.py --json
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from itertools import combinations
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from backend.classifier import cascade  # noqa: E402
from backend.classifier.text_model import TextModel  # noqa: E402
from tools.evalstats import bootstrap_ci, mcnemar_exact, wilson  # noqa: E402

DEFAULT_DATA = ROOT / "localModel" / "kakaoTalk_data" / "processed"
DICT_DIR = ROOT / "contracts" / "dictionaries"
METHODS = ["규칙", "Gemma", "자체"]


def read_jsonl(path: Path) -> dict:
    # 같은 id가 여러 줄이면 마지막 줄을 쓴다 (train_keras.read_jsonl과 같음)
    with open(path, encoding="utf-8") as f:
        return {r["id"]: r for r in map(json.loads, f)}


def load_answers(data: Path, target: str, notices: dict) -> tuple[list[str], dict]:
    """train_keras.load_test_answers + run()의 채점 대상 고르기와 같은 규칙. Gemma 임시 정답으로는 대체하지 않는다."""
    col = "정답_관심사" if target == "interest" else "정답_카테고리"
    with open(data / "review_set.csv", encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    answer = {}
    for r in rows:
        v = r[col].strip()
        if v and target == "interest":
            answer[r["id"]] = [] if v in ("없음", "-") else re.split(r"[\s,]+", v)
        elif v:
            answer[r["id"]] = v
    ids = [r["id"] for r in rows if r["id"] in answer and r["id"] in notices]
    return ids, {i: answer[i] for i in ids}


def tag_counts(ids, answer, pred, tags) -> tuple[int, int, int]:
    """맞게 붙임, 틀리게 붙임, 놓침. ids에 같은 공지가 여러 번 있으면 여러 번 센다 (부트스트랩용)."""
    hit = wrong = miss = 0
    for i in ids:
        a, p = set(answer[i]) & tags, set(pred[i]) & tags
        hit += len(a & p)
        wrong += len(p - a)
        miss += len(a - p)
    return hit, wrong, miss


def tag_f1(ids, answer, pred, tags) -> float:
    """train_keras.tag_scores의 'F1'과 같은 값."""
    hit, wrong, miss = tag_counts(ids, answer, pred, tags)
    precision = hit / (hit + wrong) if hit + wrong else 0.0
    recall = hit / (hit + miss) if hit + miss else 0.0
    return 2 * precision * recall / (precision + recall) if precision + recall else 0.0


def evaluate(data: Path) -> dict:
    notices = read_jsonl(data / "notices.jsonl")
    gemma = read_jsonl(data / "labels_gemma.jsonl")
    rule = read_jsonl(data / "labels_rule.jsonl")

    # 자체 모델 예측과 캐스케이드 애매 판정: 287건 전부 (Gemma 호출률을 전체로도 내야 해서)
    model = {}
    for i, n in notices.items():
        c = cascade.classify(n["title"], n["text"], None)
        model[i] = {"interest_ids": c.interest_ids, "category": c.category, "unsure": bool(c.unsure)}

    # ---- 종류 ----
    cat_ids, cat_answer = load_answers(data, "category", notices)
    cat_pred = {
        "규칙": {i: rule[i]["category"] for i in cat_ids},
        "Gemma": {i: gemma[i]["category"] for i in cat_ids},
        "자체": {i: model[i]["category"] for i in cat_ids},
    }
    correct = {m: {i: p[i] == cat_answer[i] for i in cat_ids} for m, p in cat_pred.items()}
    n_cat = len(cat_ids)
    category = {
        "n": n_cat,
        "accuracy": {
            m: {"correct": sum(c.values()), "acc": sum(c.values()) / n_cat, "wilson": wilson(sum(c.values()), n_cat)}
            for m, c in correct.items()
        },
        "mcnemar": [],
    }
    for a, b in [("자체", "Gemma"), ("자체", "규칙"), ("Gemma", "규칙")]:
        only_a = sum(correct[a][i] and not correct[b][i] for i in cat_ids)
        only_b = sum(correct[b][i] and not correct[a][i] for i in cat_ids)
        category["mcnemar"].append({"a": a, "b": b, "only_a": only_a, "only_b": only_b, "p": mcnemar_exact(only_a, only_b)})

    # ---- 관심사 ----
    int_ids, int_answer = load_answers(data, "interest", notices)
    learned = set(TextModel.load(cascade.INTEREST_MODEL).classes)
    all_tags = {i["id"] for i in json.loads((DICT_DIR / "interests.json").read_text(encoding="utf-8"))["items"]}
    int_pred = {
        "규칙": {i: rule[i]["interest_ids"] for i in int_ids},
        "Gemma": {i: gemma[i]["interest_ids"] for i in int_ids},
        "자체": {i: model[i]["interest_ids"] for i in int_ids},
        "캐스케이드": {i: gemma[i]["interest_ids"] if model[i]["unsure"] else model[i]["interest_ids"] for i in int_ids},
    }

    def f1_block(tags, methods):
        return {
            m: {"f1": tag_f1(int_ids, int_answer, int_pred[m], tags),
                "ci": bootstrap_ci(int_ids, lambda s, m=m: tag_f1(s, int_answer, int_pred[m], tags))}
            for m in methods
        }

    def diff_ci(a, b, tags):
        f = lambda s: tag_f1(s, int_answer, int_pred[a], tags) - tag_f1(s, int_answer, int_pred[b], tags)
        return {"a": a, "b": b, "diff": f(int_ids), "ci": bootstrap_ci(int_ids, f)}

    interest = {
        "n": len(int_ids),
        "learned_tags": sorted(learned),
        "f1_learned": f1_block(learned, METHODS),
        "f1_all_codes": f1_block(all_tags, METHODS + ["캐스케이드"]),
        "diff_learned": [diff_ci("자체", "Gemma", learned), diff_ci("자체", "규칙", learned)],
    }

    # ---- Gemma 호출률·판단 갈림 (시험 세트 / 전체) ----
    split = lambda i: set(rule[i]["interest_ids"]) != set(gemma[i]["interest_ids"])  # 규칙과 Gemma의 관심사가 다름
    rates = {
        "gemma_calls": {"test": sum(model[i]["unsure"] for i in int_ids), "test_n": len(int_ids),
                        "all": sum(m["unsure"] for m in model.values()), "all_n": len(model)},
        "split": {"test": sum(split(i) for i in int_ids), "test_n": len(int_ids),
                  "all": sum(split(i) for i in notices), "all_n": len(notices)},
    }
    return {"category": category, "interest": interest, "rates": rates}


def print_report(r: dict) -> None:
    c, it, rt = r["category"], r["interest"], r["rates"]
    print(f"채점 대상: 종류 {c['n']}건, 관심사 {it['n']}건")
    print("\n== 종류 정확도 (Wilson 95% 구간)")
    for m, s in c["accuracy"].items():
        lo, hi = s["wilson"]
        print(f"  {m:6} {s['correct']:>3}/{c['n']}  {s['acc']:.3f}  ({lo:.3f} ~ {hi:.3f})")
    print("\n== McNemar (한쪽만 맞힘, 양측 정확 p)")
    for x in c["mcnemar"]:
        print(f"  {x['a']} vs {x['b']}: {x['only_a']} 대 {x['only_b']}, p {x['p']:.3f}")
    for key, label in [("f1_learned", f"배운 꼬리표 {len(it['learned_tags'])}개 {it['learned_tags']}"),
                       ("f1_all_codes", "관심사 코드 전체")]:
        print(f"\n== 관심사 F1, {label} (부트스트랩 95% 구간)")
        for m, s in it[key].items():
            print(f"  {m:6} {s['f1']:.3f}  ({s['ci'][0]:.3f} ~ {s['ci'][1]:.3f})")
    print("\n== 관심사 F1 차, 배운 꼬리표 (부트스트랩 95% 구간)")
    for d in it["diff_learned"]:
        print(f"  {d['a']} − {d['b']}: {d['diff']:+.3f}  ({d['ci'][0]:+.3f} ~ {d['ci'][1]:+.3f})")
    g, s = rt["gemma_calls"], rt["split"]
    print(f"\n캐스케이드 Gemma 호출: 시험 {g['test']}/{g['test_n']}, 전체 {g['all']}/{g['all_n']}")
    print(f"판단 갈림(규칙·Gemma 관심사 다름): 시험 {s['test']}/{s['test_n']}, 전체 {s['all']}/{s['all_n']}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--data-dir", type=Path, default=DEFAULT_DATA)
    ap.add_argument("--json", action="store_true", help="같은 값을 JSON 한 덩어리로 출력")
    args = ap.parse_args()
    if not (args.data_dir / "notices.jsonl").exists():
        sys.exit(f"자료 없음: {args.data_dir} (git 제외 자료라 로컬에만 있음)")
    result = evaluate(args.data_dir)
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print_report(result)


if __name__ == "__main__":
    main()
