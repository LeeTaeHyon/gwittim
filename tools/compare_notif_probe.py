"""측정 앱이 폰에서 기록한 학교 채널 알림을 내보내기 본문과 짝지어 비교한다 (D-034 1주차).

알림에 본문이 얼마나 들어오는지, 알림 본문으로 분류한 결과가 내보내기 본문 판정과 같은지 잰다.
합격 기준(2단계 준비 명세 §2.1): 관심사·종류 판정 일치 95% 이상.

입력
  data/local/notif_probe/records.jsonl     측정 앱 기록 (adb pull로 받음)
  data/local/notif_probe/classified.jsonl  측정 앱의 기기 안 분류 결과
  내보내기 공지: localModel/kakaoTalk_data/processed/notices.jsonl,
                 localModel/kakaoTalk_data/collected/new_arrivals.jsonl (있으면)
출력
  화면 요약, data/local/notif_probe/compare.json (원문 없이 id·길이·판정만)

짝짓기: 같은 방, 알림 시각과 발송 시각 차이가 --window-hours 안, 알림 본문 조각의 --containment 이상이
내보내기 본문에 있음. 후보가 여럿이면 겹침이 가장 큰 공지.
같은 알림 key의 갱신은 본문이 가장 긴 것 하나로 센다. 묶음 요약 알림은 뺀다.

실행
  adb pull /sdcard/Android/data/kr.gwittim.gwittim.probe/files/notif_probe data/local/
  uv run python tools/compare_notif_probe.py
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))  # python tools/x.py 로 돌릴 때 필요

from backend.classifier import cascade  # noqa: E402
from backend.collectors.mjc_kakao.parser import shingles, title_of  # noqa: E402

PROBE_DIR = ROOT / "data/local/notif_probe"
KAKAO = ROOT / "localModel/kakaoTalk_data"
NOTICES = [KAKAO / "processed/notices.jsonl", KAKAO / "collected/new_arrivals.jsonl"]
SHORT = 200  # 이보다 짧으면 분류가 흔들린다 (준비 명세 §2.1 잘린 본문 실험)


def read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    with path.open(encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def field(record: dict, name: str) -> str | None:
    v = (record.get("fields") or {}).get(name)
    return v["value"] if v else None


def body_of(record: dict) -> tuple[str, str] | None:
    """실제 기능이 분류할 본문과 출처: 펼친 본문 > 가장 긴 메시지 > 본문 (측정 앱과 같은 규칙)."""
    big = field(record, "big_text")
    if big and big.strip():
        return big, "big_text"
    messages = [m["text"] for m in record.get("messages") or [] if m.get("text", "").strip()]
    if messages:
        return max(messages, key=len), "messages"
    text = field(record, "text")
    if text and text.strip():
        return text, "text"
    return None


def latest_per_key(records: list[dict]) -> list[dict]:
    """같은 알림 key의 갱신은 본문이 가장 긴 것 하나. 묶음 요약과 본문 없는 알림은 뺀다."""
    best: dict[str, tuple[int, dict]] = {}
    for r in records:
        if r.get("is_group_summary"):
            continue
        b = body_of(r)
        if b is None:
            continue
        n = len(b[0])
        if r["key"] not in best or n > best[r["key"]][0]:
            best[r["key"]] = (n, r)
    return sorted((r for _, r in best.values()), key=lambda r: r["post_time"])


def notice_times(n: dict) -> list[datetime]:
    keys = ("sent_at", "first_sent_at", "last_sent_at")
    return [datetime.fromisoformat(n[k]) for k in keys if n.get(k)]


def containment(part: str, whole_shingles: set[str]) -> float:
    s = shingles(part)
    return len(s & whole_shingles) / len(s) if s else 0.0


def match(record: dict, body: str, notices: list[dict], window: timedelta, threshold: float) -> tuple[dict, float] | None:
    at = datetime.fromisoformat(record["post_time"])
    best = None
    for n in notices:
        if n["room"] != record["room"]:
            continue
        if not any(abs(at - t) <= window for t in notice_times(n)):
            continue
        c = containment(body, n["_sh"])
        if c >= threshold and (best is None or c > best[1]):
            best = (n, c)
    return best


def judge(title: str, text: str) -> dict:
    r = cascade.classify(title, text)  # Gemma 없이 모델 판정과 애매함만
    return {"interest_ids": sorted(r.interest_ids), "category": r.category, "unsure": bool(r.unsure)}


def length_stats(lengths: list[int]) -> dict:
    if not lengths:
        return {"count": 0}
    s = sorted(lengths)
    return {
        "count": len(s), "min": s[0], "p10": s[(len(s) - 1) // 10], "median": statistics.median(s), "max": s[-1],
        "under_short": sum(1 for v in s if v < SHORT),
    }


def compare(probe_dir: Path, notice_paths: list[Path], window_hours: float = 3, threshold: float = 0.6) -> dict:
    records = read_jsonl(probe_dir / "records.jsonl")
    device = {c["id"]: c for c in read_jsonl(probe_dir / "classified.jsonl")}
    notices = [n for p in notice_paths for n in read_jsonl(p)]
    for n in notices:
        n["_sh"] = shingles(n["text"])

    rows, unmatched = [], []
    alerts = latest_per_key(records)
    for r in alerts:
        body, source = body_of(r)
        length = len(body)
        m = match(r, body, notices, timedelta(hours=window_hours), threshold)
        dev = device.get(r["id"])
        # 기기 안 분류가 서버 계산과 같은지 (측정 앱은 첫 줄을 제목으로 썼다)
        same_device = None
        if dev is not None:
            s = judge(dev["title"], body)
            same_device = (sorted(dev["interest_ids"]), dev["category"], bool(dev["unsure"])) == (
                s["interest_ids"], s["category"], s["unsure"])
        if m is None:
            unmatched.append({"id": r["id"], "room": r["room"], "post_time": r["post_time"], "length": length,
                              "source": source, "device_same_as_server": same_device})
            continue
        n, c = m
        mine = judge(title_of(body, r["room"]), body)
        theirs = judge(n["title"], n["text"])
        rows.append({
            "id": r["id"], "notice_id": n["id"], "room": r["room"], "post_time": r["post_time"],
            "source": source, "length": length, "notice_length": len(n["text"]), "containment": round(c, 3),
            "truncated": length < 0.9 * len(n["text"]),
            "interest_same": mine["interest_ids"] == theirs["interest_ids"],
            "category_same": mine["category"] == theirs["category"],
            "unsure_same": mine["unsure"] == theirs["unsure"],
            "device_same_as_server": same_device,
            "alert": mine, "export": theirs,
        })

    def count(key: str) -> int:
        return sum(1 for x in rows if x[key])

    device_checked = [x for x in rows + unmatched if x["device_same_as_server"] is not None]
    return {
        "records": len(records),
        "alerts": len(alerts),
        "rooms": sorted({r["room"] for r in alerts}),
        "sources": {s: sum(1 for r in alerts if body_of(r)[1] == s) for s in ("big_text", "messages", "text")},
        "length": length_stats([len(body_of(r)[0]) for r in alerts]),
        "matched": len(rows),
        "truncated": count("truncated"),
        "interest_same": count("interest_same"),
        "category_same": count("category_same"),
        "unsure_same": count("unsure_same"),
        "device_checked": len(device_checked),
        "device_same_as_server": sum(1 for x in device_checked if x["device_same_as_server"]),
        "pairs": rows,
        "unmatched": unmatched,
    }


def pct(a: int, b: int) -> str:
    return f"{a}/{b} ({a / b:.0%})" if b else "0/0"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="측정 앱 알림 기록과 내보내기 본문 비교")
    ap.add_argument("--probe-dir", type=Path, default=PROBE_DIR)
    ap.add_argument("--notices", type=Path, nargs="+", default=NOTICES)
    ap.add_argument("--window-hours", type=float, default=3)
    ap.add_argument("--containment", type=float, default=0.6)
    ap.add_argument("--out", type=Path, default=None, help="기본: <probe-dir>/compare.json")
    args = ap.parse_args(argv)

    if not (args.probe_dir / "records.jsonl").exists():
        print(f"{args.probe_dir / 'records.jsonl'} 없음. adb pull로 먼저 받는다.")
        return 1
    result = compare(args.probe_dir, args.notices, args.window_hours, args.containment)
    out = args.out or args.probe_dir / "compare.json"
    out.write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")

    L, m = result["length"], result["matched"]
    print(f"기록 {result['records']}줄, 알림 {result['alerts']}건 (방 {len(result['rooms'])}곳)")
    print(f"본문 출처: {result['sources']}")
    if L["count"]:
        print(f"본문 글자 수: 최소 {L['min']}, 10% {L['p10']}, 중앙값 {L['median']}, 최대 {L['max']}, "
              f"{SHORT}자 미만 {L['under_short']}건")
    print(f"내보내기 공지와 짝지음: {pct(m, result['alerts'])}, 그중 잘린 본문 {result['truncated']}건")
    print(f"관심사 판정 일치 {pct(result['interest_same'], m)}, 종류 {pct(result['category_same'], m)}, "
          f"애매함 {pct(result['unsure_same'], m)} (기준 95%)")
    print(f"기기 안 분류 = 서버 계산: {pct(result['device_same_as_server'], result['device_checked'])}")
    print(f"→ {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
