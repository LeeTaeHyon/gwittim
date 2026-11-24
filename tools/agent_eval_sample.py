"""품질 평가 1단계: 상세 분석 표본 40건·외부 찾기 질의 18개를 뽑아 고정하고 정답 양식을 만든다 (agent-quality-eval-spec §5.1·§5.3·§6.1).

실행(저장소 루트, data/local은 메인 폴더 것을 준다)
  python tools/agent_eval_sample.py --data <메인>/data/local            # 뽑아서 고정(이미 있으면 멈춤)
  python tools/agent_eval_sample.py --data <메인>/data/local --check    # 씨앗으로 다시 뽑아 같은 목록인지만 확인

규칙
- 출처 묶음별 건수(§5.1 표), 안내형 분류 8건, 마감 지난 공고 4건까지, 폰 미리보기·명단형·본문 없음 제외
- 묶음 안에서 (본문 길이 3분위 × 분류) 칸을 돌아가며 한 건씩 뽑는다. 3분위 경계는 묶음 안 후보로 정한다
- 고치며 볼 30건 / 보지 않는 10건은 묶음별로 나눈다(HOLDOUT_QUOTA)

출력: <data>/agent_eval/
- sample/manifest.json: 씨앗, 기준 날짜, 원본 해시, 표본 목록(키·묶음·분류·길이 칸·마감 지남·split)
- sample/notices.json, sample/records.json: 표본 공고와 원문 복사본(배치가 notices.json을 바꾸므로 고정)
- queries.json: 외부 찾기 질의 18개
- gold/dev_packets.md: 고치며 볼 30건 읽기 자료(본문·무료 화면 칸), gold/gold_template.csv: 정답 양식
- gold/holdout/packets.md, gold/holdout/gold_template.csv: 보지 않는 10건(사람만 씀. 이 도구는 화면에 내용을 찍지 않음)
"""
from __future__ import annotations

import argparse
import csv
import random
import sys
from collections import defaultdict
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tools.agent_eval_common import (  # noqa: E402
    FREE_SCREEN_FIELDS, GROUP_QUOTA, GROUPS, HOLDOUT_QUOTA, INFO_CATEGORIES, INFO_TOTAL, PASSED_MAX, ROSTER,
    data_dir, eval_dir, free_screen_text, group_of, query_set, read_json, sha256_file, write_json,
)

SEED = 20261124
GOLD_COLUMNS = ["notice_id", "fact", "quote", "kind", "on_free_screen", "annotator", "memo"]
KINDS = "자격 / 일정 / 장소·방식 / 과업·제출물 / 혜택 / 비용·조건 / 기타"


def body_of(record: dict) -> str:
    return ((record or {}).get("raw") or {}).get("body_text") or ""


def candidates(notices: dict, records: dict) -> tuple[dict[str, list[str]], dict[str, int]]:
    """묶음별 후보 키와 제외 사유 건수."""
    pool, dropped = defaultdict(list), defaultdict(int)
    for key, n in notices.items():
        group = group_of(key, n)
        if group is None:
            dropped["묶음 밖"] += 1
        elif n.get("body_preview"):
            dropped["폰 미리보기"] += 1
        elif ROSTER.search(n.get("title") or ""):
            dropped["명단형"] += 1
        elif len(body_of(records.get(key)).strip()) < 20:
            dropped["본문 없음"] += 1
        else:
            pool[group].append(key)
    for keys in pool.values():
        keys.sort()
    return dict(pool), dict(dropped)


def tertile(lengths: list[int]) -> tuple[int, int]:
    s = sorted(lengths)
    return s[len(s) // 3], s[(2 * len(s)) // 3]


def length_band(n: int, cuts: tuple[int, int]) -> str:
    return "짧음" if n < cuts[0] else ("중간" if n < cuts[1] else "긺")


def info_quota(pool: dict[str, list[str]], notices: dict) -> dict[str, int]:
    """안내형 8건을 묶음별 안내형 후보 수에 비례해 나눈다(묶음 건수의 절반까지)."""
    avail = {g: sum(notices[k].get("category") in INFO_CATEGORIES for k in keys) for g, keys in pool.items()}
    total = sum(avail.values()) or 1
    quota = {g: min(avail[g], GROUP_QUOTA[g] // 2, round(INFO_TOTAL * avail[g] / total)) for g in pool}
    order = sorted(pool, key=lambda g: (-avail[g], g))
    while sum(quota.values()) != INFO_TOTAL:
        step = 1 if sum(quota.values()) < INFO_TOTAL else -1
        moved = False
        for g in order:
            new = quota[g] + step
            if 0 <= new <= min(avail[g], GROUP_QUOTA[g] // 2):
                quota[g] = new
                moved = True
                break
        if not moved:
            break
    return quota


def pick(keys: list[str], k: int, cell_of, rng: random.Random, can_take) -> list[str]:
    """칸을 돌아가며 한 건씩 k건. can_take(key)가 False면 건너뛴다."""
    cells = defaultdict(list)
    for key in keys:
        cells[cell_of(key)].append(key)
    names = sorted(cells)
    rng.shuffle(names)
    for name in names:
        rng.shuffle(cells[name])
    out = []
    while len(out) < k and any(cells.values()):
        for name in names:
            while cells[name]:
                key = cells[name].pop()
                if can_take(key):
                    out.append(key)
                    break
            if len(out) == k:
                break
    return out


def draw(notices: dict, records: dict, today: date, seed: int = SEED) -> tuple[list[dict], dict]:
    pool, dropped = candidates(notices, records)
    rng = random.Random(seed)
    quota = info_quota(pool, notices)
    passed_left = [PASSED_MAX]

    def passed(key: str) -> bool:
        day = (notices[key].get("application_deadline") or {}).get("date")
        return bool(day) and day < today.isoformat()

    def can_take(key: str) -> bool:
        if passed(key):
            if passed_left[0] == 0:
                return False
            passed_left[0] -= 1
        return True

    rows = []
    for group in GROUPS:  # 정해진 순서로 돌아 씨앗이 같으면 같은 결과
        keys = pool.get(group, [])
        cuts = tertile([len(body_of(records[k])) for k in keys])

        def cell(key: str) -> tuple[str, str]:
            return length_band(len(body_of(records[key])), cuts), notices[key].get("category") or "-"

        info = [k for k in keys if notices[k].get("category") in INFO_CATEGORIES]
        rest = [k for k in keys if notices[k].get("category") not in INFO_CATEGORIES]
        chosen = pick(info, quota.get(group, 0), cell, rng, can_take)
        chosen += pick(rest, GROUP_QUOTA[group] - len(chosen), cell, rng, can_take)
        holdout = set(rng.sample(sorted(chosen), HOLDOUT_QUOTA[group]))
        for key in sorted(chosen):
            band, cat = cell(key)
            rows.append({"key": key, "group": group, "category": cat, "length_band": band,
                         "body_chars": len(body_of(records[key])), "deadline_passed": passed(key),
                         "split": "holdout" if key in holdout else "dev"})
    meta = {"seed": seed, "today": today.isoformat(), "pool": {g: len(v) for g, v in pool.items()},
            "dropped": dropped, "info_quota": quota}
    return rows, meta


def packet(rows: list[dict], notices: dict, records: dict, title: str) -> str:
    out = [f"# {title}", "", "- 단위: 원문 본문만 보고 '알면 지원 여부나 준비가 달라지는 사실'을 공고당 최대 5개. 0개도 답",
           f"- 종류: {KINDS}",
           "- 무료 화면에 있음: 아래 '무료 화면' 줄에 같은 사실이 보이면 예, 아니면 아니요",
           "- 원문 문장은 본문에서 그대로 복사(대조에 씀)", "", "무료 화면 칸(앱 공고 상세, 크레딧 없이 보임)", ""]
    out += [f"- {f}" for f in FREE_SCREEN_FIELDS]
    for i, r in enumerate(rows, 1):
        n, rec = notices[r["key"]], records[r["key"]]
        raw = rec.get("raw") or {}
        out += ["", "---", "", f"## {i}. {n.get('title')}", "", f"- notice_id: `{r['key']}`",
                f"- 출처 묶음: {GROUPS[r['group']]} · 분류: {r['category']} · 본문 {r['body_chars']}자"
                + (" · 마감 지남" if r["deadline_passed"] else ""),
                f"- 첨부: {', '.join(a.get('file_name') or '?' for a in raw.get('attachments') or []) or '없음'}"
                + " (첨부는 읽지 않음)", "", "무료 화면", ""]
        out += [f"- {ln}" for ln in free_screen_text(n)]
        out += ["", "본문", "", "```text", body_of(rec).strip(), "```"]
    return "\n".join(out) + "\n"


def write_template(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=GOLD_COLUMNS)
        w.writeheader()
        for r in rows:  # 공고마다 빈 줄 하나. 사실이 여러 개면 줄을 더한다. 0개면 fact에 '없음'
            w.writerow({"notice_id": r["key"]})


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--data", help="메인 폴더의 data/local (기본: 환경변수 GWITTIM_DATA)")
    ap.add_argument("--today", type=date.fromisoformat, default=date(2026, 11, 24), help="마감 지남 기준 날짜")
    ap.add_argument("--check", action="store_true", help="고정된 표본을 씨앗으로 다시 뽑아 같은지만 확인")
    args = ap.parse_args(argv)
    data = data_dir(args.data)
    out = eval_dir(data)
    sample_dir = out / "sample"
    manifest_path = sample_dir / "manifest.json"

    if args.check:
        m = read_json(manifest_path)
        rows, _ = draw(read_json(sample_dir / "notices.json"), read_json(sample_dir / "records.json"),
                       date.fromisoformat(m["today"]), m["seed"])
        same = [(r["key"], r["split"]) for r in rows] == [(r["key"], r["split"]) for r in m["sample"]]
        print("같은 목록" if same else "다른 목록")
        return 0 if same else 1

    if manifest_path.exists():
        print(f"이미 고정된 표본이 있습니다: {manifest_path} (다시 뽑지 않음)")
        return 1
    notices_path, records_path = data / "notices.json", data / "pipeline/records.json"
    notices, records = read_json(notices_path), read_json(records_path)
    rows, meta = draw(notices, records, args.today)
    keys = [r["key"] for r in rows]
    # 표본 복사본은 후보 전체를 담는다: --check가 같은 후보 풀로 다시 뽑을 수 있게. 원문 본문은 data/local에만 둔다
    write_json(sample_dir / "notices.json", notices)
    write_json(sample_dir / "records.json", records)
    write_json(manifest_path, {**meta, "source_hashes": {"notices.json": sha256_file(notices_path),
                                                         "pipeline/records.json": sha256_file(records_path)},
                               "sample": rows})
    write_json(out / "queries.json", query_set())

    dev = [r for r in rows if r["split"] == "dev"]
    hold = [r for r in rows if r["split"] == "holdout"]
    gold = out / "gold"
    (gold / "dev_packets.md").parent.mkdir(parents=True, exist_ok=True)
    (gold / "dev_packets.md").write_text(packet(dev, notices, records, "정답지 읽기 자료 (고치며 볼 30건)"),
                                         encoding="utf-8")
    write_template(gold / "gold_template.csv", dev)
    (gold / "holdout").mkdir(parents=True, exist_ok=True)
    (gold / "holdout/packets.md").write_text(packet(hold, notices, records, "정답지 읽기 자료 (보지 않는 10건, 사람만)"),
                                             encoding="utf-8")
    write_template(gold / "holdout/gold_template.csv", hold)

    # 화면에는 건수만 찍는다(보지 않는 10건의 제목·본문을 Claude가 보지 않게)
    print(f"표본 {len(rows)}건 (dev {len(dev)}, holdout {len(hold)}), 씨앗 {meta['seed']}, 기준 {meta['today']}")
    for g in GROUPS:
        part = [r for r in rows if r["group"] == g]
        print(f"- {GROUPS[g]}: {len(part)}건 (holdout {sum(r['split'] == 'holdout' for r in part)})")
    print(f"- 안내형 {sum(r['category'] in INFO_CATEGORIES for r in rows)}건, 마감 지남 "
          f"{sum(r['deadline_passed'] for r in rows)}건")
    print(f"- 후보 {meta['pool']}, 제외 {meta['dropped']}")
    print(f"결과: {out}")
    return 0 if len(keys) == sum(GROUP_QUOTA.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
