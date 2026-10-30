"""알림톡 분류 모델 학습·비교 (「모두의 딥러닝」 21장 방식: 토큰화 → 임베딩 → LSTM → Dense).

입력 (kakaoTalk_data/processed/)
  notices.jsonl       알림톡 공지 본문 (kakao_preprocess.py)
  labels_gemma.jsonl  Gemma 라벨 = 학습 정답 (label_gemma.py)
  labels_rule.jsonl   규칙 라벨 = 비교 기준 (make_review_set.py)
  review_set.csv      시험 세트 50건. '정답_*' 칸을 사람이 채운 행만 채점에 쓴다 (꼬리표 없음은 '없음')
  board_notices.jsonl + labels_gemma_board.jsonl
                      게시판 공고 보강분 (board_notices.py). 학습에만 보태고 검증·시험은 알림톡만 쓴다
출력 (models/)
  <실험>.keras        학습된 모델 (토큰화가 끝난 숫자 입력을 받는다)
  <실험>_vocab.json   단어장·정답 코드·문턱값 (새 알림톡을 같은 방식으로 토큰화할 때 필요)
  <실험>.json         지표
  <실험>_test.csv     시험 세트 공지별 정답·규칙·Gemma·내 모델 예측

사용 (.venv의 파이썬 3.12)
  .venv/Scripts/python train_keras.py                     관심사, 단어 단위, LSTM
  .venv/Scripts/python train_keras.py --unit char         글자 단위 토큰화
  .venv/Scripts/python train_keras.py --arch avg          LSTM 대신 평균 풀링
  .venv/Scripts/python train_keras.py --target category   카테고리 (softmax 다중 분류)
  .venv/Scripts/python train_keras.py --all               관심사 4가지 조합을 모두 돌려 표로 비교
  .venv/Scripts/python train_keras.py --board             게시판 공고 보강분을 학습에 보탬 (보강 효과 비교용)

학습 뒤 export_weights.py로 가중치를 backend/classifier/models/에 꺼내면 앱 배치가 쓴다 (D-019).

관심사 모델은 배운 꼬리표 외에 '기타' 출력을 하나 더 둔다 (Gemma 라벨에 배운 적 없는 꼬리표가 있으면 1).
이 확률과 문턱값 근처의 애매한 확률을 보고 Gemma로 넘기는 캐스케이드를 시험 세트로 시뮬레이션한다.
"""
import argparse
import csv
import json
import os
import re
import time
from collections import Counter

import numpy as np
import tensorflow as tf
from tensorflow.keras import callbacks, layers, models

BASE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(BASE, "kakaoTalk_data", "processed")
OUT = os.path.join(BASE, "models")
DICT_DIR = os.path.join(os.path.dirname(BASE), "contracts", "dictionaries")

SEQ_LEN = {"word": 200, "char": 600}  # 공지 하나를 토큰 몇 개까지 볼지
MAX_TOKENS = {"word": 8000, "char": 2000}  # 단어장 크기 상한
VAL_RATIO = 0.15  # 학습 데이터 중 검증용 비율
GEMMA_SECONDS = 1.1  # label_gemma.py 실행 때 공고당 평균 (gemma4:12b, RX 9070)
URL_RE = re.compile(r"https?://\S+")
OTHER = "기타"  # 관심사 모델의 마지막 출력: 배운 적 없는 꼬리표가 있을 확률
# 캐스케이드 정책: (이름, 꼬리표 확률이 문턱값 ± 이 범위 안이면 '애매'). 기타 확률은 항상 검증 세트로 정한 문턱을 쓴다
CASCADE_POLICIES = [
    ("기타", 0.0),
    ("기타 또는 문턱 ±0.05", 0.05),
    ("기타 또는 문턱 ±0.1", 0.1),
]


# ---------- 데이터 ----------

def read_jsonl(name):
    with open(os.path.join(DATA, name), encoding="utf-8") as f:
        return {r["id"]: r for r in map(json.loads, f)}


def all_interest_codes():
    with open(os.path.join(DICT_DIR, "interests.json"), encoding="utf-8") as f:
        return {i["id"] for i in json.load(f)["items"]}


def text_of(notice):
    # 링크는 주소마다 달라서 단어장만 키우므로 뺀다
    return URL_RE.sub(" ", notice["title"] + "\n" + notice["text"])


def load_test_answers(target, gemma):
    """시험 세트 정답. 사람이 채운 행만 쓰고, 하나도 없으면 Gemma 라벨을 임시 정답으로 쓴다."""
    col = "정답_관심사" if target == "interest" else "정답_카테고리"
    with open(os.path.join(DATA, "review_set.csv"), encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    test_ids = [r["id"] for r in rows]
    human = {}
    for r in rows:
        v = r[col].strip()
        if v and target == "interest":
            human[r["id"]] = [] if v in ("없음", "-") else re.split(r"[\s,]+", v)
        elif v:
            human[r["id"]] = v
    if human:
        return test_ids, human, False
    key = "interest_ids" if target == "interest" else "category"
    return test_ids, {i: gemma[i][key] for i in test_ids}, True


# ---------- 모델 ----------

def build_model(vocab_size, n_out, arch, multi_label):
    model = models.Sequential([
        layers.Input(shape=(None,), dtype="int64"),
        layers.Embedding(vocab_size, 64, mask_zero=True),  # 단어 번호 → 64차원 벡터, 0(빈칸)은 무시
        layers.LSTM(32) if arch == "lstm" else layers.GlobalAveragePooling1D(),
        layers.Dropout(0.3),
        # 관심사는 한 공지에 여러 개가 붙을 수 있어 꼬리표마다 독립 확률(sigmoid), 카테고리는 하나만 고르므로 softmax
        layers.Dense(n_out, activation="sigmoid" if multi_label else "softmax"),
    ])
    model.compile(
        optimizer="adam",
        loss="binary_crossentropy" if multi_label else "sparse_categorical_crossentropy",
    )
    return model


# ---------- 채점 ----------

def tag_scores(answer, pred, tags):
    """관심사 다중 라벨 채점. tags 밖 코드는 양쪽 모두에서 무시한다."""
    hit = wrong = miss = exact = has_ok = 0
    for i, a in answer.items():
        a, p = set(a) & tags, set(pred[i]) & tags
        hit += len(a & p)  # 맞게 붙임
        wrong += len(p - a)  # 틀리게 붙임
        miss += len(a - p)  # 놓침
        exact += a == p
        has_ok += bool(a) == bool(p)
    precision = hit / (hit + wrong) if hit + wrong else 0.0
    recall = hit / (hit + miss) if hit + miss else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    n = len(answer)
    return {"정확히_일치": exact / n, "정밀도": precision, "재현율": recall, "F1": f1, "있음없음_정확도": has_ok / n}


def best_threshold(probs, ids, answer, tags):
    """검증 세트에서 F1이 가장 높은 문턱값. 시험 세트는 보지 않는다. answer: {id: 꼬리표 목록}"""
    answer = {i: answer[i] for i in ids}
    best_f1, best_th = -1.0, 0.5
    for th in np.arange(0.1, 0.91, 0.05):
        pred = {i: [t for t, p in zip(tags, row) if p >= th] for i, row in zip(ids, probs)}
        f1 = tag_scores(answer, pred, set(tags))["F1"]
        if f1 > best_f1:
            best_f1, best_th = f1, round(float(th), 2)
    return best_th


# ---------- 실험 하나 ----------

def run(target, unit, arch, min_count=5, epochs=60, board=False, verbose=True, board_weight=1.0):
    tf.keras.utils.set_random_seed(0)
    multi = target == "interest"
    key = "interest_ids" if multi else "category"
    name = f"{target}_{unit}_{arch}" + ("_board" if board else "")

    # 1. 데이터: 시험 세트는 학습에서 뺀다
    notices = read_jsonl("notices.jsonl")
    gemma = read_jsonl("labels_gemma.jsonl")
    rule = read_jsonl("labels_rule.jsonl")
    review_ids, answer, provisional = load_test_answers(target, gemma)
    # 검수 대상은 정답을 채웠든 안 채웠든 학습에서 빼고, 채운 행만 채점한다
    # (전처리에서 공통 공지가 아니게 된 행은 채점에서도 뺀다)
    test_ids = [i for i in review_ids if i in answer and i in notices]
    answer = {i: answer[i] for i in test_ids}
    train_ids = [i for i in notices if i in gemma and i not in set(review_ids)]

    # 2. 학습/검증 나누기: 파일이 방 순서라 섞고 나눈다
    order = np.random.default_rng(0).permutation(len(train_ids))
    n_val = int(len(order) * VAL_RATIO)
    val_ids = [train_ids[k] for k in order[:n_val]]
    tr_ids = [train_ids[k] for k in order[n_val:]]

    # 게시판 공고 보강: 학습 세트에만 보탠다 (검증·시험은 실제로 분류할 알림톡으로 유지)
    n_board, board_set = 0, set()
    if board and os.path.exists(os.path.join(DATA, "labels_gemma_board.jsonl")):
        board_notices, board_labels = read_jsonl("board_notices.jsonl"), read_jsonl("labels_gemma_board.jsonl")
        board_ids = [i for i in board_notices if i in board_labels]
        notices.update(board_notices)
        gemma.update(board_labels)
        tr_ids += board_ids
        n_board, board_set = len(board_ids), set(board_ids)

    # 3. 정답 만들기
    if multi:
        counts = Counter(t for i in tr_ids for t in gemma[i][key])
        classes = sorted(t for t, c in counts.items() if c >= min_count)  # 예시가 너무 적은 꼬리표는 못 배운다
        dropped = sorted(t for t, c in counts.items() if c < min_count)
        # 마지막 칸 '기타': 배운 꼬리표 밖의 꼬리표가 하나라도 있으면 1 → 모델이 "내가 모르는 분야"를 알아채게 한다
        to_y = lambda ids: np.array(
            [[t in gemma[i][key] for t in classes] + [any(t not in classes for t in gemma[i][key])] for i in ids],
            dtype="float32")
    else:
        counts = Counter(gemma[i][key] for i in tr_ids)
        classes, dropped = sorted(counts), []
        to_y = lambda ids: np.array([classes.index(gemma[i][key]) for i in ids])

    # 4. 토큰화: 학습 세트로만 단어장을 만들고, 모든 공지를 같은 단어장으로 숫자로 바꾼다
    tokenizer = layers.TextVectorization(
        max_tokens=MAX_TOKENS[unit],
        split="whitespace" if unit == "word" else "character",
        output_sequence_length=SEQ_LEN[unit],
    )
    tokenizer.adapt([text_of(notices[i]) for i in tr_ids])
    to_x = lambda ids: tokenizer([text_of(notices[i]) for i in ids]).numpy()
    x_tr, x_val, x_test = to_x(tr_ids), to_x(val_ids), to_x(test_ids)

    # 5. 학습: 검증 손실이 6번 연속 나빠지면 멈추고 가장 좋았던 가중치로 되돌린다 (과적합 방지)
    model = build_model(tokenizer.vocabulary_size(), len(classes) + (1 if multi else 0), arch, multi)
    # 게시판 공고는 알림톡과 꼬리표 분포가 달라 손실에 board_weight만큼만 반영할 수 있다
    weights = np.array([board_weight if i in board_set else 1.0 for i in tr_ids], dtype="float32")
    model.fit(
        x_tr, to_y(tr_ids), sample_weight=weights, validation_data=(x_val, to_y(val_ids)), epochs=epochs,
        batch_size=16, verbose=0,
        callbacks=[callbacks.EarlyStopping(patience=6, restore_best_weights=True)],
    )

    # 6. 예측: 관심사는 검증 세트로 문턱값을 정한 뒤 시험 세트에 적용
    n_tags = len(classes)
    threshold = other_threshold = None
    if multi:
        val_probs = model.predict(x_val, verbose=0)
        threshold = best_threshold(val_probs[:, :n_tags], val_ids, {i: gemma[i][key] for i in val_ids}, classes)
        # '기타'도 확률이 낮게 나오므로 같은 방식으로 검증 세트에서 문턱을 정한다
        val_other = {i: [OTHER] if any(t not in classes for t in gemma[i][key]) else [] for i in val_ids}
        other_threshold = best_threshold(val_probs[:, n_tags:], val_ids, val_other, [OTHER])
    model.predict(x_test[:1], verbose=0)  # 첫 호출 준비 시간은 속도 측정에서 뺀다
    t0 = time.perf_counter()
    for k in range(len(test_ids)):  # 앱에서처럼 한 건씩 넣었을 때 속도
        model.predict(x_test[k : k + 1], verbose=0)
    ms_each = (time.perf_counter() - t0) / len(test_ids) * 1000
    probs = model.predict(x_test, verbose=0)
    if multi:
        mine = {i: [t for t, p in zip(classes, row[:n_tags]) if p >= threshold] for i, row in zip(test_ids, probs)}
    else:
        mine = {i: classes[int(np.argmax(row))] for i, row in zip(test_ids, probs)}

    # 7. 채점: 같은 시험 세트로 기준선·규칙·Gemma·내 모델 비교
    methods = {
        "규칙": {i: rule[i][key] for i in test_ids},
        "Gemma 12b": {i: gemma[i][key] for i in test_ids},
        "내 모델": mine,
    }
    if multi:
        methods = {"항상 꼬리표 없음": {i: [] for i in test_ids}, **methods}
        scores = {m: tag_scores(answer, p, set(classes)) for m, p in methods.items()}
    else:
        top = counts.most_common(1)[0][0]
        methods = {f"항상 '{top}'": {i: top for i in test_ids}, **methods}
        scores = {m: {"정확도": sum(p[i] == answer[i] for i in test_ids) / len(test_ids)} for m, p in methods.items()}

    # 7-2. 캐스케이드: 내 모델이 애매하거나 '모르는 분야'라고 하면 Gemma 라벨로 바꿔 끼운다.
    #      채점은 사전의 관심사 코드 전체로 (내 모델이 못 배운 꼬리표도 놓침으로 센다)
    cascade = []
    if multi:
        all_tags = all_interest_codes()
        tag_p, other_p = probs[:, :n_tags], probs[:, n_tags]

        def cascade_row(label, to_gemma, model_ms=ms_each):
            pred = {i: gemma[i][key] if g else mine[i] for i, g in zip(test_ids, to_gemma)}
            rate = float(np.mean(to_gemma))
            return {"방법": label, "Gemma_호출": rate, **tag_scores(answer, pred, all_tags),
                    "ms": model_ms + rate * GEMMA_SECONDS * 1000}

        no_one, every = np.zeros(len(test_ids), bool), np.ones(len(test_ids), bool)
        cascade.append({"방법": "규칙", "Gemma_호출": 0.0, **tag_scores(answer, methods["규칙"], all_tags), "ms": 0.0})
        cascade.append(cascade_row("내 모델만", no_one))
        for label, band in CASCADE_POLICIES:
            unsure = (other_p >= other_threshold) | (np.abs(tag_p - threshold) < band).any(axis=1)
            cascade.append(cascade_row(f"내 모델 → Gemma ({label})", unsure))
        cascade.append(cascade_row("Gemma만", every, 0.0))

    # 8. 저장
    os.makedirs(OUT, exist_ok=True)
    model_path = os.path.join(OUT, f"{name}.keras")
    model.save(model_path)
    with open(os.path.join(OUT, f"{name}_vocab.json"), "w", encoding="utf-8") as f:
        json.dump({"unit": unit, "seq_len": SEQ_LEN[unit], "classes": classes, "threshold": threshold,
                   "other_threshold": other_threshold,
                   "vocab": tokenizer.get_vocabulary()}, f, ensure_ascii=False)
    info = {"name": name, "provisional_answer": provisional, "train": len(tr_ids), "board": n_board, "val": len(val_ids),
            "test": len(test_ids), "classes": classes, "dropped": dropped, "threshold": threshold,
            "other_threshold": other_threshold, "scores": scores,
            "cascade": cascade, "params": model.count_params(), "size_kb": round(os.path.getsize(model_path) / 1024),
            "ms_per_notice": ms_each}
    with open(os.path.join(OUT, f"{name}.json"), "w", encoding="utf-8") as f:
        json.dump(info, f, ensure_ascii=False, indent=2)
    with open(os.path.join(OUT, f"{name}_test.csv"), "w", encoding="utf-8-sig", newline="") as f:
        fmt = (lambda v: " ".join(v) or "없음") if multi else str
        w = csv.writer(f)
        w.writerow(["id", "제목", "정답", "규칙", "Gemma", "내 모델"] + ([f"{OTHER}_확률"] if multi else []))
        for k, i in enumerate(test_ids):
            w.writerow([i, notices[i]["title"][:60], fmt(answer[i]), fmt(rule[i][key]), fmt(gemma[i][key]), fmt(mine[i])]
                       + ([f"{probs[k, n_tags]:.2f}"] if multi else []))

    if verbose:
        print_report(info)
    return info


def print_report(info):
    board = f" (게시판 보강 {info['board']} 포함)" if info.get("board") else ""
    print(f"\n== {info['name']}  (학습 {info['train']}{board} / 검증 {info['val']} / 시험 {info['test']}건)")
    if info["provisional_answer"]:
        print("※ 사람 검수 전이라 Gemma 라벨을 임시 정답으로 채점함 (Gemma 점수는 의미 없음)")
    print("정답 코드:", info["classes"])
    if info["dropped"]:
        print("학습 예시가 적어 뺀 코드:", info["dropped"])
    if info["threshold"] is not None:
        print(f"문턱값 (검증 세트로 정함): 꼬리표 {info['threshold']}, {OTHER} {info['other_threshold']}")
    cols = list(next(iter(info["scores"].values())))
    print("\n" + "방법".ljust(14) + "".join(c.rjust(10) for c in cols))
    for m, s in info["scores"].items():
        print(m.ljust(14) + "".join(f"{s[c]:.2f}".rjust(10) for c in cols))
    print(f"\n내 모델: 파라미터 {info['params']:,}개, 파일 {info['size_kb']:,}KB, 공고당 {info['ms_per_notice']:.0f}ms (CPU)")
    print(f"Gemma 12b: 파일 약 8GB, 공고당 약 {GEMMA_SECONDS}s (GPU)")
    if info.get("cascade"):
        print("\n== 캐스케이드 (관심사 코드 전체로 채점, 공고당 시간은 Gemma 호출 비율로 추정)")
        cols = ["Gemma_호출", "정확히_일치", "정밀도", "재현율", "F1"]
        print("방법".ljust(36) + "".join(c.rjust(10) for c in cols) + "ms".rjust(8))
        for r in info["cascade"]:
            print(r["방법"].ljust(36) + f"{r['Gemma_호출']:.0%}".rjust(10)
                  + "".join(f"{r[c]:.2f}".rjust(10) for c in cols[1:]) + f"{r['ms']:.0f}".rjust(8))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", choices=["interest", "category"], default="interest")
    ap.add_argument("--unit", choices=["word", "char"], default="word")
    ap.add_argument("--arch", choices=["lstm", "avg"], default="lstm")
    ap.add_argument("--min-count", type=int, default=5, help="학습 세트에 이보다 적게 나온 꼬리표는 뺀다")
    ap.add_argument("--epochs", type=int, default=60)
    ap.add_argument("--all", action="store_true", help="관심사 단어/글자 × LSTM/평균 풀링 4가지 비교")
    # 2026-10-30 실험: 관심사는 보강하면 오히려 나빠짐(장학·채용 공고와 알림톡의 꼬리표 분포가 다름), 카테고리는 비슷 → 기본은 끔
    ap.add_argument("--board", action="store_true", help="게시판 공고(board_notices.jsonl)를 학습에 보탠다")
    ap.add_argument("--board-weight", type=float, default=1.0, help="게시판 공고의 손실 가중치 (알림톡은 1)")
    args = ap.parse_args()
    board = args.board

    if not args.all:
        run(args.target, args.unit, args.arch, args.min_count, args.epochs, board, board_weight=args.board_weight)
        return
    results = [run("interest", u, a, args.min_count, args.epochs, board, verbose=False)
               for u in ("word", "char") for a in ("lstm", "avg")]
    print_report(results[0])
    print("\n== 조합 비교 (내 모델)")
    print("실험".ljust(24) + "정확히_일치".rjust(10) + "F1".rjust(8) + "파라미터".rjust(12) + "ms".rjust(6))
    for r in results:
        s = r["scores"]["내 모델"]
        print(r["name"].ljust(24) + f"{s['정확히_일치']:.2f}".rjust(10) + f"{s['F1']:.2f}".rjust(8)
              + f"{r['params']:,}".rjust(12) + f"{r['ms_per_notice']:.0f}".rjust(6))


if __name__ == "__main__":
    main()
