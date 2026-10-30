"""PC 카톡 '대화 내보내기' txt → 학습용 알림톡 데이터.

입력: kakaoTalk_data/*.txt (원본, git 제외)
출력: kakaoTalk_data/processed/
  messages.csv   전체 메시지 + 분류(kind) + 중복 그룹
  notices.jsonl  학습용: 공통 공지(broadcast)만, 중복 묶음당 1건, 개인정보 가림

파싱·분류·가림·중복 묶기는 앱 수집기와 같은 코드(backend/collectors/mjc_kakao/parser.py)를 쓴다.
알림 종류(kind) 설명도 그 파일에 있다.
"""
import collections
import csv
import glob
import json
import os
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(BASE))  # 저장소 루트 (backend 패키지)

from backend.collectors.mjc_kakao.parser import mask, read_exports, title_of  # noqa: E402

__all__ = ["mask", "title_of"]  # board_notices.py가 같은 가림·제목 규칙을 쓴다

RAW_DIR = os.path.join(BASE, "kakaoTalk_data")
OUT_DIR = os.path.join(RAW_DIR, "processed")


def main():
    files = sorted(glob.glob(os.path.join(RAW_DIR, "*.txt")))
    if not files:
        sys.exit(f"내보내기 파일이 없습니다: {RAW_DIR}")
    msgs, groups = read_exports(files)
    n_names = sum(1 for m in msgs if "<이름>" in m["masked"] and "<이름>" not in m["text"])

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(os.path.join(OUT_DIR, "messages.csv"), "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["id", "room", "sent_at", "kind", "dup_group", "title", "text"])
        for m in msgs:
            w.writerow([m["id"], m["room"], m["sent_at"], m["kind"], m["dup_group"], m["title"], m["masked"]])

    notices = []
    for gid, ms in groups.items():
        first = ms[0]
        if first["kind"] != "broadcast":
            continue
        notices.append({
            "id": gid,
            "room": first["room"],
            "title": first["title"],
            "text": first["masked"],
            "urls": first["urls"],
            "first_sent_at": first["sent_at"],
            "last_sent_at": ms[-1]["sent_at"],
            "send_count": len(ms),
        })
    with open(os.path.join(OUT_DIR, "notices.jsonl"), "w", encoding="utf-8") as f:
        for n in notices:
            f.write(json.dumps(n, ensure_ascii=False) + "\n")

    # 요약 출력 (본문·이름은 출력하지 않음)
    print(f"파일 {len(files)}개, 메시지 {len(msgs)}건, 이름을 가린 메시지 {n_names}건")
    kinds = collections.Counter(m["kind"] for m in msgs)
    print("분류:", dict(kinds))
    print(f"중복 묶음 {len(groups)}개 → 학습용 공통 공지 {len(notices)}건")
    by_room = collections.Counter(n["room"] for n in notices)
    for room in sorted({m["room"] for m in msgs}):
        rk = collections.Counter(m["kind"] for m in msgs if m["room"] == room)
        print(f"  {room}: 메시지 {sum(rk.values())} {dict(rk)} → 공지 {by_room[room]}")
    resent = sorted(notices, key=lambda n: -n["send_count"])[:5]
    print("재발송 많은 공지:", [(n["send_count"], n["title"][:30]) for n in resent])


if __name__ == "__main__":
    main()
