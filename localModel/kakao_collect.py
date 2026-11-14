"""새로 들어온 알림톡 모으기. 내보내기를 몇 번 빼먹어도, 같은 파일을 여러 번 넣어도 결과가 같다.

사용
  1. PC 카톡에서 학교 채널 대화를 내보내 kakaoTalk_data/inbox/에 그대로 넣는다. 지우지 않는다.
     (대화 내보내기는 그때까지의 대화를 통째로 담으므로 빼먹은 기간은 다음 내보내기에 들어온다)
  2. python kakao_collect.py
  3. 화면에 '애매한 쌍'이 나오면 collected/dup_review.csv의 '판단' 칸에 같음/다름을 적고 다시 돌린다.

기준 데이터
  kakaoTalk_data/*.txt (10/29 학습용 내보내기)는 건드리지 않는다. 라벨 표의 g번호가 이 파일 순서로 매겨져 있다.
  방마다 기준 파일의 마지막 메시지 이후에 처음 온 공통 공지(broadcast)만 '새 공지'로 본다.
  기준 공지의 재발송은 파서의 중복 묶기(같은 방·45일·본문 80% 이상)로 묶여 새 공지가 되지 않는다.

출력 (kakaoTalk_data/collected/, git 제외)
  ledger.jsonl       지금까지 본 새 공지 대장. 한 번 들어온 공지는 이후 파일에서 빠져도 남는다.
  new_arrivals.jsonl 대장에서 '같음'으로 판단한 공지를 뺀 것. 나중에 라벨을 매겨 학습 이후 시험 세트로 쓴다.
  dup_review.csv     자동으로 묶이지 않은 비슷한 쌍 (같은 방 유사도 0.6~0.8, 다른 방 0.6 이상, 같은 방 45일 넘게 떨어진 0.8 이상)

본문은 파서가 학번·휴대폰·교수·수신자 이름을 가린 글만 저장한다. 공지 ID는 방·발송 시각·가리기 전 본문의 해시라
가림 규칙이나 함께 읽은 파일이 달라져도 바뀌지 않는다.
"""
from __future__ import annotations

import argparse
import csv
import glob
import hashlib
import json
import os
import re
import sys
from datetime import datetime

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(BASE))  # 저장소 루트 (backend 패키지)

from backend.collectors.mjc_kakao.parser import jaccard, read_exports, room_of, shingles  # noqa: E402

RAW_DIR = os.path.join(BASE, "kakaoTalk_data")
SIMILAR = 0.6  # 이 이상 비슷한데 자동으로 묶이지 않은 쌍은 사람이 본다
STALE_DAYS = 7  # 마지막 내보내기가 이보다 오래되면 경고
REVIEW_COLUMNS = ["new_id", "other_id", "유사도", "방_새", "방_기존", "발송_새", "발송_기존", "제목_새", "제목_기존", "판단"]
SAME, DIFFERENT = "같음", "다름"
EXPORT_TS_RE = re.compile(r"KakaoTalk_(\d{8})_(\d{4})")


def export_time(path: str) -> datetime | None:
    m = EXPORT_TS_RE.match(os.path.basename(path))
    return datetime.strptime("".join(m.groups()), "%Y%m%d%H%M") if m else None


def msg_key(m: dict) -> str:
    """방·발송 시각·가리기 전 본문 → ID. 가림 결과와 무관해서 실행마다 같다."""
    return "n" + hashlib.sha1(f"{m['room']}|{m['sent_at']}|{m['text']}".encode("utf-8")).hexdigest()[:12]


def latest_per_room(paths: list[str]) -> dict[str, str]:
    """방마다 가장 최근에 내보낸 파일 하나 (최신 파일이 이전 기록을 모두 담는다)."""
    out: dict[str, str] = {}
    for p in sorted(paths, key=lambda p: (export_time(p) or datetime.min, p)):
        out[room_of(p)] = p
    return out


def broadcast_groups(paths):
    """[(대표 메시지, 묶음 크기)] 공통 공지 묶음만, 그리고 전체 메시지."""
    msgs, groups = read_exports(paths)
    return [(ms[0], len(ms)) for ms in groups.values() if ms[0]["kind"] == "broadcast"], msgs


def read_jsonl(path):
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        return {r["id"]: r for r in map(json.loads, filter(str.strip, f))}


def write_jsonl(path, rows):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")


def read_review(path):
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8-sig") as f:
        return {(r["new_id"], r["other_id"]): r["판단"].strip() for r in csv.DictReader(f)}


def similar_pairs(new, others):
    """new 공지마다 자동으로 묶이지 않았지만 비슷한 공지. new: {id: rec}, others: {id: rec} (rec에 sh·room·day)."""
    pairs = []
    for nid, n in new.items():
        for oid, o in others.items():
            if oid == nid or (oid in new and oid > nid):  # 새 공지끼리는 한 번만
                continue
            j = jaccard(n["sh"], o["sh"])
            if j < SIMILAR:
                continue
            same_room = n["room"] == o["room"]
            far = abs((n["day"] - o["day"]).days) > 45
            if not same_room or j < 0.8 or far:  # 같은 방·45일 안·0.8 이상은 파서가 이미 묶었다
                pairs.append((nid, oid, j))
    return pairs


def collect(raw_dir=RAW_DIR, now=None):
    now = now or datetime.now()
    inbox = sorted(glob.glob(os.path.join(raw_dir, "inbox", "*.txt")))
    base_files = sorted(glob.glob(os.path.join(raw_dir, "*.txt")))
    out_dir = os.path.join(raw_dir, "collected")
    if not inbox:
        sys.exit(f"inbox가 비어 있습니다: {os.path.join(raw_dir, 'inbox')}\nPC 카톡 대화 내보내기 파일을 여기에 넣으세요.")
    os.makedirs(out_dir, exist_ok=True)
    warnings = []

    base_groups, base_msgs = broadcast_groups(base_files) if base_files else ([], [])
    cutoff = {}
    for m in base_msgs:
        cutoff[m["room"]] = max(cutoff.get(m["room"], ""), m["sent_at"])
    base_keys = {msg_key(m) for m in base_msgs}

    latest = latest_per_room(inbox)
    groups, msgs = broadcast_groups(list(latest.values()))
    inbox_keys = {msg_key(m) for m in msgs}

    for room in sorted(set(latest) - set(cutoff)):
        warnings.append(f"처음 보는 방: {room} (기준 파일이 없어 이 방의 공지는 모두 새 공지로 봄)")
    for room in sorted(set(cutoff) - set(latest)):
        warnings.append(f"inbox에 없는 방: {room}")
    lost = {}
    for m in base_msgs:
        if m["room"] in latest and msg_key(m) not in inbox_keys:
            lost[m["room"]] = lost.get(m["room"], 0) + 1
    for room, k in sorted(lost.items()):
        warnings.append(f"{room}: 기준 파일에 있던 메시지 {k}건이 최신 내보내기에 없음 (PC 카톡 기록이 잘렸을 수 있음)")
    last_export = max(t for t in map(export_time, inbox) if t) if any(map(export_time, inbox)) else None
    if last_export and (now - last_export).days > STALE_DAYS:
        warnings.append(f"마지막 내보내기가 {(now - last_export).days}일 전 ({last_export:%m/%d})")

    ledger_path = os.path.join(out_dir, "ledger.jsonl")
    ledger = read_jsonl(ledger_path)
    added = 0
    for first, size in groups:
        if first["sent_at"] <= cutoff.get(first["room"], ""):
            continue  # 기준 이전 공지와 그 재발송
        key = msg_key(first)
        if key in base_keys:
            continue
        seen = export_time(latest[first["room"]])
        rec = ledger.get(key)
        if rec is None:
            added += 1
            ledger[key] = {"id": key, "room": first["room"], "sent_at": first["sent_at"], "title": first["title"],
                           "text": first["masked"], "sends": size,
                           "first_seen_export": seen.strftime("%Y-%m-%dT%H:%M") if seen else None}
        else:
            rec["sends"] = max(rec["sends"], size)
    rows = sorted(ledger.values(), key=lambda r: (r["sent_at"], r["id"]))
    write_jsonl(ledger_path, rows)

    # 애매한 쌍: 새 공지 ↔ (기준 공지 + 대장의 다른 공지)
    def rec_of(room, sent_at, title, text):
        return {"room": room, "sent_at": sent_at, "title": title, "sh": shingles(text),
                "day": datetime.fromisoformat(sent_at[:10])}

    new = {r["id"]: rec_of(r["room"], r["sent_at"], r["title"], r["text"]) for r in rows}
    others = {**{msg_key(f): rec_of(f["room"], f["sent_at"], f["title"], f["masked"]) for f, _ in base_groups}, **new}
    review_path = os.path.join(out_dir, "dup_review.csv")
    judged = read_review(review_path)
    review_rows = []
    for nid, oid, j in sorted(similar_pairs(new, others), key=lambda p: -p[2]):
        n, o = new[nid], others[oid]
        review_rows.append({"new_id": nid, "other_id": oid, "유사도": f"{j:.2f}", "방_새": n["room"], "방_기존": o["room"],
                            "발송_새": n["sent_at"][:16], "발송_기존": o["sent_at"][:16],
                            "제목_새": n["title"], "제목_기존": o["title"], "판단": judged.get((nid, oid), "")})
    with open(review_path, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=REVIEW_COLUMNS)
        w.writeheader()
        w.writerows(review_rows)

    bad = [r for r in review_rows if r["판단"] not in ("", SAME, DIFFERENT)]
    for r in bad:
        warnings.append(f"dup_review.csv 판단 칸은 '{SAME}' 또는 '{DIFFERENT}' ({r['new_id']}: '{r['판단']}')")
    # '같음'이면 나중에 온 쪽을 뺀다
    dropped = set()
    for r in review_rows:
        if r["판단"] == SAME:
            a, b = r["new_id"], r["other_id"]
            later = a if b not in new or (new[a]["sent_at"], a) > (new[b]["sent_at"], b) else b
            dropped.add(later)
    pending = [r for r in review_rows if not r["판단"]]
    arrivals = [r for r in rows if r["id"] not in dropped]
    write_jsonl(os.path.join(out_dir, "new_arrivals.jsonl"), arrivals)

    print("방별 마지막 알림 (최신 내보내기 기준)")
    last_by_room = {}
    for m in msgs:
        last_by_room[m["room"]] = max(last_by_room.get(m["room"], ""), m["sent_at"])
    for room, t in sorted(last_by_room.items()):
        print(f"  {room.replace('명지전문대학', '').strip():14} {t[5:10].replace('-', '/')} {t[11:16]}")
    print(f"새 공지 +{added}건 (대장 {len(rows)}건, '같음'으로 뺀 {len(dropped)}건 → new_arrivals {len(arrivals)}건)")
    if pending:
        print(f"애매한 쌍 {len(pending)}개 → {review_path} '판단' 칸에 {SAME}/{DIFFERENT}")
        for r in pending[:10]:
            print(f"  {r['유사도']}  {r['제목_새'][:28]}  ↔  {r['제목_기존'][:28]}")
    for w_ in warnings:
        print(f"⚠ {w_}")
    return {"added": added, "ledger": len(rows), "arrivals": len(arrivals), "pending": len(pending), "warnings": warnings}


def main(argv=None):
    ap = argparse.ArgumentParser(description="inbox의 카톡 내보내기에서 새 알림톡 모으기")
    ap.add_argument("--raw-dir", default=RAW_DIR, help="기준 *.txt와 inbox/가 있는 폴더 (기본 kakaoTalk_data)")
    args = ap.parse_args(argv)
    collect(args.raw_dir)


if __name__ == "__main__":
    main()
