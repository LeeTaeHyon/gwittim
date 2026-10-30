"""학교 홈페이지 게시판 공고(앱 수집 파이프라인 결과) → 알림톡과 같은 형식의 학습 보강 데이터.

입력: ../data/local/pipeline/records.json (앱 로컬 배치가 모은 원문)
      kakaoTalk_data/processed/board_history.json (board_history.py가 모은 지난 공고, 있으면 합침)
출력: kakaoTalk_data/processed/board_notices.jsonl
  학습에만 보태고 시험에는 쓰지 않는다 (시험은 알림톡 사람 검수 세트).
  이후 label_gemma.py --input board_notices.jsonl --out labels_gemma_board.jsonl 로 라벨을 붙인다.
"""
import collections
import json
import os

from kakao_preprocess import mask, title_of

BASE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BASE)
RECORDS = os.path.join(ROOT, "data", "local", "pipeline", "records.json")
HISTORY = os.path.join(BASE, "kakaoTalk_data", "processed", "board_history.json")
OUT = os.path.join(BASE, "kakaoTalk_data", "processed", "board_notices.jsonl")


def main():
    records = {}
    if os.path.exists(HISTORY):
        with open(HISTORY, encoding="utf-8") as f:
            records.update(json.load(f))
    with open(RECORDS, encoding="utf-8") as f:
        records.update(json.load(f))  # 같은 공고면 정기 수집 쪽(더 최근 원문)을 쓴다
    notices = []
    for key, rec in records.items():
        if rec.get("removed") or not key.startswith("mjc_www_"):  # 알림톡 기록(mjc_kakao)은 이미 학습 데이터에 있음
            continue
        raw = rec["raw"]
        text = mask((raw.get("body_text") or "").strip(), names=set())
        title = (raw.get("title") or "").strip() or title_of(text, "")
        if not title and not text:
            continue
        notices.append({
            "id": key,  # 예: mjc_www_notice:BD0050390080 (알림톡 g0001과 겹치지 않음)
            "room": raw["source_id"],
            "title": title,
            "text": text,  # 본문이 이미지뿐인 공고는 빈 문자열 → 제목만으로 학습
            "first_sent_at": (raw.get("published") or {}).get("date"),
        })
    with open(OUT, "w", encoding="utf-8") as f:
        for n in notices:
            f.write(json.dumps(n, ensure_ascii=False) + "\n")
    by_source = collections.Counter(n["room"] for n in notices)
    print(f"게시판 공고 {len(notices)}건 {dict(by_source)}, 본문 없음 {sum(1 for n in notices if not n['text'])}건 → {OUT}")


if __name__ == "__main__":
    main()
