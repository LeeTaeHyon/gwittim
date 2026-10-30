"""알림톡 공지에 Gemma(Ollama)로 정답 초안(관심사·카테고리·전체 대상 여부)을 붙인다.

입력: kakaoTalk_data/processed/notices.jsonl (kakao_preprocess.py 결과)
출력: kakaoTalk_data/processed/labels_gemma.jsonl (이어서 실행 가능, 이미 라벨링한 id는 건너뜀)

사용: python label_gemma.py [--limit N] [--model gemma4:12b]
      python label_gemma.py --input board_notices.jsonl --out labels_gemma_board.jsonl   게시판 공고 보강분
"""
import argparse
import json
import os
import random
import sys
import time

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(BASE))  # 저장소 루트 (backend 패키지)

# 프롬프트·응답 검증은 앱 배치의 캐스케이드와 같은 코드를 쓴다
from backend.classifier.gemma_tags import chat, validate  # noqa: E402

PROC = os.path.join(BASE, "kakaoTalk_data", "processed")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int)
    ap.add_argument("--sample", type=int, help="무작위 N건만 (프롬프트 점검용)")
    ap.add_argument("--model", default="gemma4:12b")
    ap.add_argument("--input", default="notices.jsonl", help="processed/ 안의 공지 파일 (게시판 보강: board_notices.jsonl)")
    ap.add_argument("--out", default="labels_gemma.jsonl", help="processed/ 안의 출력 파일")
    args = ap.parse_args()
    args.out = os.path.join(PROC, args.out)

    with open(os.path.join(PROC, args.input), encoding="utf-8") as f:
        notices = [json.loads(l) for l in f]
    done = set()
    if os.path.exists(args.out):
        with open(args.out, encoding="utf-8") as f:
            done = {json.loads(l)["id"] for l in f}
    todo = [n for n in notices if n["id"] not in done]
    if args.sample:
        todo = random.Random(0).sample(todo, min(args.sample, len(todo)))
    todo = todo[: args.limit]
    print(f"전체 {len(notices)}건, 완료 {len(done)}건, 이번 {len(todo)}건", flush=True)

    failed = 0
    with open(args.out, "a", encoding="utf-8") as f:
        for k, n in enumerate(todo, 1):
            t0 = time.time()
            try:
                label = validate(chat(args.model, n["title"], n["text"]))
            except Exception as e:  # 실패 건은 기록하지 않고 다음 실행 때 다시 시도
                failed += 1
                print(f"[{k}/{len(todo)}] {n['id']} 실패: {type(e).__name__}", flush=True)
                continue
            f.write(json.dumps({"id": n["id"], "model": args.model, **label}, ensure_ascii=False) + "\n")
            f.flush()
            print(f"[{k}/{len(todo)}] {n['id']} {time.time() - t0:.1f}s {label['category']} {label['interest_ids']}", flush=True)
    print(f"끝. 실패 {failed}건")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
