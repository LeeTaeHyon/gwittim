"""품질 평가 §16.7: 사람 정답 두 벌을 대조·합치고, 초안과의 일치율을 낸다.

실행(저장소 루트)
  python tools/agent_eval_gold.py --data <메인>/data/local

- 입력(읽기만): gold/dev_gold_THL.csv, gold/dev_gold_TMK.csv, gold/dev_draft.csv
- 같은 사실: 같은 공고에서 원문 문장(quote)이 같은 곳을 가리킴 = 공백·기호를 지운 문장이 같거나 한쪽이 다른 쪽을 포함(§5.3).
  한 사실은 한 번만 짝짓는다(겹침이 긴 순서로 탐욕 짝짓기)
- 일치율 = 둘 다 적은 사실 ÷ 한쪽이라도 적은 사실. '무료 화면에 있음'은 짝지은 사실끼리 같은 비율
- 사람 정답 = 두 사람 합집합(gold/dev_gold_human.csv, 이 도구가 새로 씀). 사실 id는 공고마다 H1…
  '무료 화면에 있음'이 갈리면 '예'로 둔다: 새 사실(M4)은 두 사람 모두 화면에 없다고 본 것만 센다(보수적)
"""
from __future__ import annotations

import argparse
import csv
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tools.agent_eval_common import data_dir, eval_dir, norm, write_json  # noqa: E402
from tools.agent_eval_score import _rate  # noqa: E402

COLUMNS = ["notice_id", "id", "fact", "quote", "kind", "on_free_screen", "sources", "free_screen_split"]


def read_facts(path: Path) -> dict[str, list[dict]]:
    with path.open(encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    out = defaultdict(list)
    for r in rows:
        out.setdefault(r["notice_id"], [])
        if (r.get("fact") or "").strip() not in ("", "없음"):
            out[r["notice_id"]].append(r)
    return dict(out)


def same(a: dict, b: dict) -> bool:
    x, y = norm(a.get("quote") or ""), norm(b.get("quote") or "")
    return bool(x) and bool(y) and (x == y or x in y or y in x)


def pair(a: list[dict], b: list[dict]) -> list[tuple[int, int]]:
    """같은 사실 짝(인덱스). 겹침이 긴 쌍부터 한 번씩."""
    cands = sorted(((min(len(norm(x["quote"])), len(norm(y["quote"]))), i, j)
                    for i, x in enumerate(a) for j, y in enumerate(b) if same(x, y)), reverse=True)
    used_a, used_b, out = set(), set(), []
    for _, i, j in cands:
        if i not in used_a and j not in used_b:
            used_a.add(i)
            used_b.add(j)
            out.append((i, j))
    return out


def agreement(a: dict, b: dict) -> dict:
    both = union = free_same = 0
    for k in set(a) | set(b):
        fa, fb = a.get(k, []), b.get(k, [])
        p = pair(fa, fb)
        both += len(p)
        union += len(fa) + len(fb) - len(p)
        free_same += sum(fa[i]["on_free_screen"] == fb[j]["on_free_screen"] for i, j in p)
    return {"facts_matched": both, "facts_union": union, "fact_agreement": _rate(both, union),
            "free_screen_agreement": _rate(free_same, both)}


def merge(a: dict, b: dict, la: str, lb: str) -> dict[str, list[dict]]:
    out = {}
    for k in sorted(set(a) | set(b)):
        fa, fb = a.get(k, []), b.get(k, [])
        p = dict(pair(fa, fb))
        rows = []
        for i, x in enumerate(fa):
            if i in p:
                y = fb[p[i]]
                split = x["on_free_screen"] != y["on_free_screen"]
                rows.append({**x, "on_free_screen": "예" if split else x["on_free_screen"],
                             "sources": f"{la}+{lb}", "free_screen_split": "예" if split else ""})
            else:
                rows.append({**x, "sources": la, "free_screen_split": ""})
        rows += [{**y, "sources": lb, "free_screen_split": ""} for j, y in enumerate(fb) if j not in p.values()]
        for n, r in enumerate(rows, 1):
            r["id"] = f"H{n}"
        out[k] = rows
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--data")
    args = ap.parse_args(argv)
    gold = eval_dir(data_dir(args.data)) / "gold"
    thl, tmk, draft = (read_facts(gold / f) for f in ("dev_gold_THL.csv", "dev_gold_TMK.csv", "dev_draft.csv"))
    human = merge(thl, tmk, "THL", "TMK")
    result = {
        "counts": {"THL": sum(map(len, thl.values())), "TMK": sum(map(len, tmk.values())),
                   "draft": sum(map(len, draft.values())), "human_union": sum(map(len, human.values())),
                   "human_union_not_on_free_screen": sum(r["on_free_screen"] == "아니요" for v in human.values() for r in v),
                   "free_screen_split": sum(r["free_screen_split"] == "예" for v in human.values() for r in v)},
        "THL_vs_TMK": agreement(thl, tmk), "THL_vs_draft": agreement(thl, draft),
        "TMK_vs_draft": agreement(tmk, draft), "human_union_vs_draft": agreement(human, draft),
    }
    with (gold / "dev_gold_human.csv").open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS, extrasaction="ignore")
        w.writeheader()
        for k, rows in human.items():
            if not rows:
                w.writerow({"notice_id": k, "fact": "없음"})
            for r in rows:
                w.writerow(r)
    write_json(gold.parent / "scores/gold_agreement.json", result)
    for k, v in result.items():
        print(k, v)
    return 0


if __name__ == "__main__":
    sys.exit(main())
