"""새 알림톡 분류 시험: 앱 배치와 같은 캐스케이드(backend/classifier/cascade.py)를 공지 몇 건에 돌려 본다.

내 모델(export_weights.py로 꺼낸 가중치)이 먼저 분류하고, 애매하면 Gemma(Ollama)에 넘긴다.
  · 기타 확률 ≥ 기타 문턱: 배운 적 없는 분야일 수 있음
  · 꼬리표 확률이 문턱 ± 0.05 안: 붙일지 말지 경계
Gemma가 꺼져 있거나 실패하면 내 모델 결과를 쓴다. 표준 라이브러리만 쓰므로 어느 파이썬으로도 돌아간다.

입력 (셋 중 하나)
  --text "본문"              공지 하나 (첫 줄을 제목으로 쓴다)
  --file 공지.txt            파일 하나 = 공지 하나 / .jsonl이면 한 줄에 {"title", "text"} 하나
  --ids g0001 g0002          kakaoTalk_data/processed/notices.jsonl 안의 공지

사용
  python predict.py --text "2026 AI 해커톤 참가자 모집 ..."
  python predict.py --ids g0006 g0031 --no-gemma      Gemma 없이 내 모델만
  python predict.py --file new.jsonl --out result.jsonl
"""
import argparse
import json
import os
import sys
import time
from dataclasses import asdict

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(BASE))  # 저장소 루트 (backend 패키지)

from backend.classifier.cascade import OTHER, classify, ollama  # noqa: E402
from backend.classifier.text_model import TextModel  # noqa: E402
from backend.collectors.mjc_kakao.parser import mask, title_of  # noqa: E402

DATA = os.path.join(BASE, "kakaoTalk_data", "processed")
SOURCE_LABEL = {"model": "내 모델", "gemma": "Gemma", "model_gemma_failed": "내 모델 (Gemma 실패)"}


def load_notices(args):
    if args.text:
        text = mask(args.text.strip(), names=())
        return [{"id": "text", "title": title_of(text, ""), "text": text}]
    if args.file:
        with open(args.file, encoding="utf-8") as f:
            rows = [json.loads(l) for l in f if l.strip()] if args.file.endswith(".jsonl") else [{"text": f.read()}]
        out = []
        for k, r in enumerate(rows):
            text = mask((r.get("text") or "").strip(), names=())
            out.append({"id": r.get("id", f"f{k:04d}"), "title": r.get("title") or title_of(text, ""), "text": text})
        return out
    with open(os.path.join(DATA, "notices.jsonl"), encoding="utf-8") as f:
        notices = {r["id"]: r for r in map(json.loads, f)}
    missing = [i for i in args.ids if i not in notices]
    if missing:
        sys.exit(f"notices.jsonl에 없는 id: {missing}")
    return [notices[i] for i in args.ids]


def main():
    ap = argparse.ArgumentParser()
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--text")
    src.add_argument("--file")
    src.add_argument("--ids", nargs="+")
    ap.add_argument("--gemma", default="gemma4:12b", help="애매할 때 부를 Ollama 모델")
    ap.add_argument("--no-gemma", action="store_true", help="Gemma를 부르지 않고 내 모델 결과만")
    ap.add_argument("--out", help="결과를 jsonl로 저장할 경로")
    args = ap.parse_args()

    gemma = None if args.no_gemma else ollama(args.gemma)
    results = []
    for n in load_notices(args):
        t0 = time.perf_counter()
        c = classify(n["title"], n["text"], gemma)
        ms = (time.perf_counter() - t0) * 1000
        results.append({"id": n["id"], "title": n["title"][:60], **asdict(c), "ms": round(ms)})
        probs = ", ".join(f"{t} {p:.2f}" for t, p in c.interest_probs.items())
        print(f"\n[{n['id']}] {n['title'][:60]}")
        print(f"  확률      {probs}, {OTHER} {c.other_prob:.2f}")
        if c.unsure:
            print(f"  애매함    {'; '.join(c.unsure)}")
        print(f"  → 최종    관심사 {c.interest_ids or '없음'}  카테고리 {c.category}  [{SOURCE_LABEL[c.source]}, {ms:.0f}ms]")

    interest = TextModel.load("interest_char_avg")
    sent = sum(1 for r in results if r["unsure"])
    print(f"\n{len(results)}건 중 애매한 공지 {sent}건"
          f" (관심사 문턱 {interest.threshold}, {OTHER} 문턱 {interest.other_threshold})")
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            for r in results:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        print(f"저장: {args.out}")


if __name__ == "__main__":
    main()
