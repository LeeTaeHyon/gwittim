"""품질 평가 1단계 보완 (agent-quality-eval-spec §15): 기준 날짜·상태, 사람이 쓸 10건, 고정본·정답 초안 해시.

실행(저장소 루트)
  python tools/agent_eval_prep.py --data <메인>/data/local dates     # sample/eval_dates.json
  python tools/agent_eval_prep.py --data <메인>/data/local human     # gold/human_dev.json·packets·template (있으면 멈춤)
  python tools/agent_eval_prep.py --data <메인>/data/local hash      # 고정본 해시 + 정답 초안 해시(gold/hashes.json)
  python tools/agent_eval_prep.py --data <메인>/data/local check-draft  # 초안 원문 문장이 본문에 있는지

- 표본(sample/manifest.json)은 읽기만 한다. 다시 뽑지 않는다
- 보지 않는 10건의 내용은 화면에 찍지 않는다(id도 찍지 않음, 건수만)
"""
from __future__ import annotations

import argparse
import csv
import random
import sys
from datetime import date, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from backend.recommendation.config import EXCLUDED_LIFECYCLE  # noqa: E402
from backend.recommendation.ranking import is_stale  # noqa: E402
from tools.agent_eval_common import data_dir, eval_dir, quote_in, read_json, sha256_file, write_json  # noqa: E402
from tools.agent_eval_sample import GOLD_COLUMNS, body_of, packet, write_template  # noqa: E402

MEASURE_DAY = date(2026, 11, 24)  # 측정일(§5.1)
HUMAN_SEED = 20261125
HUMAN_N = 10


def eval_dates(rows: list[dict], notices: dict, measure_day: date = MEASURE_DAY) -> dict:
    """표본 행마다 기준 날짜(게시일, 없으면 측정일)와 측정일 기준 앱 노출 상태."""
    out, passed = [], []
    for r in rows:
        n = notices[r["key"]]
        pub = (n.get("published") or {}).get("date")
        today = pub or measure_day.isoformat()
        life = n.get("lifecycle_status")
        stale = is_stale({**n, "published": n.get("published")}, measure_day)
        deadline = (n.get("application_deadline") or {}).get("date")
        if deadline and deadline < today:
            passed.append(r["key"])
        out.append({"key": r["key"], "split": r["split"], "group": r["group"], "eval_today": today,
                    "today_from": "published" if pub else "measure_day", "lifecycle_status": life, "stale": stale,
                    "visible": life not in EXCLUDED_LIFECYCLE and not stale, "deadline": deadline})
    return {"measure_day": measure_day.isoformat(), "rows": out,
            "counts": {"visible": sum(x["visible"] for x in out),
                       "visible_by_group": {g: sum(x["visible"] for x in out if x["group"] == g)
                                            for g in dict.fromkeys(x["group"] for x in out)},
                       "closed": sum(x["lifecycle_status"] == "closed" for x in out),
                       "stale": sum(x["stale"] for x in out)},
            "deadline_passed_at_eval_today": {"count": len(passed), "keys": passed}}


def pick_human(dev_keys: list[str], seed: int = HUMAN_SEED, k: int = HUMAN_N) -> list[str]:
    """고치며 볼 30건에서 사람이 따로 쓸 10건. 표본 뽑기와 다른 난수."""
    return sorted(random.Random(seed).sample(sorted(dev_keys), k))


def today_map(data: Path) -> dict[str, date]:
    """실행 도구용: 키 -> 기준 날짜."""
    rows = read_json(eval_dir(data) / "sample/eval_dates.json")["rows"]
    return {r["key"]: date.fromisoformat(r["eval_today"]) for r in rows}


def read_draft(path: Path) -> list[dict]:
    with path.open(encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def check_draft(rows: list[dict], records: dict) -> list[str]:
    """원문 문장이 본문에 없는 줄. '없음' 줄(사실 0개)은 건너뛴다."""
    bad = []
    for i, r in enumerate(rows, 2):
        if (r.get("fact") or "").strip() in ("", "없음"):
            continue
        if not quote_in(r.get("quote") or "", body_of(records.get(r["notice_id"]))):
            bad.append(f"{i}행 {r['notice_id']}: 원문 문장이 본문에 없음")
    return bad


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--data")
    ap.add_argument("cmd", choices=("dates", "human", "hash", "check-draft"))
    args = ap.parse_args(argv)
    out = eval_dir(data_dir(args.data))
    manifest = read_json(out / "sample/manifest.json")
    rows = manifest["sample"]
    gold = out / "gold"

    if args.cmd == "dates":
        result = eval_dates(rows, read_json(out / "sample/notices.json"))
        write_json(out / "sample/eval_dates.json", result)
        print(f"보이는 것 {result['counts']['visible']}건 {result['counts']['visible_by_group']}, "
              f"closed {result['counts']['closed']}건, stale {result['counts']['stale']}건")
        p = result["deadline_passed_at_eval_today"]
        dev_passed = [k for k in p["keys"] if next(r for r in rows if r["key"] == k)["split"] == "dev"]
        print(f"기준 날짜에 이미 마감 지난 공고 {p['count']}건 (dev: {dev_passed}, holdout {p['count'] - len(dev_passed)}건)")
        return 0

    if args.cmd == "human":
        if (gold / "human_dev.json").exists():
            print("이미 고정돼 있습니다(다시 뽑지 않음)")
            return 1
        dev = [r for r in rows if r["split"] == "dev"]
        keys = pick_human([r["key"] for r in dev])
        write_json(gold / "human_dev.json", {"seed": HUMAN_SEED, "keys": keys})
        chosen = [r for r in dev if r["key"] in keys]
        notices, records = read_json(out / "sample/notices.json"), read_json(out / "sample/records.json")
        (gold / "human_dev_packets.md").write_text(
            packet(chosen, notices, records, "정답지 읽기 자료 (고치며 볼 30건 중 사람이 쓸 10건, 초안 없이)"),
            encoding="utf-8")
        write_template(gold / "human_dev_template.csv", chosen)
        print(f"사람이 쓸 10건: {keys}")
        return 0

    if args.cmd == "check-draft":
        bad = check_draft(read_draft(gold / "dev_draft.csv"), read_json(out / "sample/records.json"))
        print("\n".join(bad) or "원문 문장 전부 본문에 있음")
        return 1 if bad else 0

    # hash
    path = gold / "hashes.json"
    hashes = read_json(path) if path.exists() else {}
    for name in ("sample/notices.json", "sample/records.json", "queries.json"):
        hashes.setdefault(name, {"sha256": sha256_file(out / name), "at": datetime.now().isoformat(timespec="seconds")})
    draft = gold / "dev_draft.csv"
    if draft.exists():
        now = sha256_file(draft)
        old = hashes.get("gold/dev_draft.csv")
        if old and old["sha256"] != now:
            print("정답 초안이 고정 뒤 바뀌었습니다. 해시를 덮어쓰지 않습니다")
            return 1
        hashes.setdefault("gold/dev_draft.csv", {"sha256": now, "at": datetime.now().isoformat(timespec="seconds")})
    write_json(path, hashes)
    for k, v in hashes.items():
        print(f"{k}: {v['sha256'][:23]}… {v['at']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
