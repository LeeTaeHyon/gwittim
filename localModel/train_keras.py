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
  .venv/Scripts/python train_keras.py --cv --unit char --arch avg
                                                          사람 정답으로 채점하는 교차 검증 (labels_human.jsonl 필요)

학습 뒤 export_weights.py로 가중치를 backend/classifier/models/에 꺼내면 앱 배치가 쓴다 (D-019).

관심사 모델은 배운 꼬리표 외에 '기타' 출력을 하나 더 둔다 (Gemma 라벨에 배운 적 없는 꼬리표가 있으면 1).
이 확률과 문턱값 근처의 애매한 확률을 보고 Gemma로 넘기는 캐스케이드를 시험 세트로 시뮬레이션한다.
"""
import argparse
import csv
import hashlib
import json
import os
import re
import sys
import time
from collections import Counter
from types import SimpleNamespace

import numpy as np
import tensorflow as tf
from tensorflow.keras import callbacks, layers, models

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(BASE))
from tools.evalstats import bootstrap_ci, mcnemar_exact, stratified_folds, wilson  # noqa: E402

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


# ---------- 학습 한 번 ----------

def fit(target, unit, arch, tr_ids, val_ids, notices, gemma, min_count=5, epochs=60, board_set=frozenset(),
        board_weight=1.0):
    """학습 세트로 정답 코드·단어장을 정하고 학습한 뒤, 관심사는 검증 세트로 문턱값을 정한다.

    시험(채점) 공지는 받지 않는다. 단어장·조기 종료·문턱값 어디에도 시험 공지가 들어가지 않게 하려는 것.
    난수 씨앗은 부르는 쪽에서 tf.keras.utils.set_random_seed로 정한다.
    """
    multi = target == "interest"
    key = "interest_ids" if multi else "category"

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
    x_tr, x_val = to_x(tr_ids), to_x(val_ids)

    # 5. 학습: 검증 손실이 6번 연속 나빠지면 멈추고 가장 좋았던 가중치로 되돌린다 (과적합 방지)
    model = build_model(tokenizer.vocabulary_size(), len(classes) + (1 if multi else 0), arch, multi)
    # 게시판 공고는 알림톡과 꼬리표 분포가 달라 손실에 board_weight만큼만 반영할 수 있다
    weights = np.array([board_weight if i in board_set else 1.0 for i in tr_ids], dtype="float32")
    model.fit(
        x_tr, to_y(tr_ids), sample_weight=weights, validation_data=(x_val, to_y(val_ids)), epochs=epochs,
        batch_size=16, verbose=0,
        callbacks=[callbacks.EarlyStopping(patience=6, restore_best_weights=True)],
    )

    # 6. 관심사 문턱값: 검증 세트에서 F1이 가장 높은 값
    n_tags = len(classes)
    threshold = other_threshold = None
    if multi:
        val_probs = model.predict(x_val, verbose=0)
        threshold = best_threshold(val_probs[:, :n_tags], val_ids, {i: gemma[i][key] for i in val_ids}, classes)
        # '기타'도 확률이 낮게 나오므로 같은 방식으로 검증 세트에서 문턱을 정한다
        val_other = {i: [OTHER] if any(t not in classes for t in gemma[i][key]) else [] for i in val_ids}
        other_threshold = best_threshold(val_probs[:, n_tags:], val_ids, val_other, [OTHER])
    return SimpleNamespace(model=model, tokenizer=tokenizer, to_x=to_x, counts=counts, classes=classes,
                           dropped=dropped, threshold=threshold, other_threshold=other_threshold)


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

    # 3~6. 정답 만들기, 토큰화, 학습, 문턱값
    fitted = fit(target, unit, arch, tr_ids, val_ids, notices, gemma, min_count, epochs, board_set, board_weight)
    model, tokenizer, counts = fitted.model, fitted.tokenizer, fitted.counts
    classes, dropped = fitted.classes, fitted.dropped
    threshold, other_threshold = fitted.threshold, fitted.other_threshold
    n_tags = len(classes)
    x_test = fitted.to_x(test_ids)

    # 6. 예측: 관심사는 검증 세트로 정한 문턱값을 시험 세트에 적용
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


# ---------- 교차 검증: Gemma 라벨로 학습, 사람 정답으로 채점 (docs/stage2-work-spec.md W3) ----------
#
# 사람 정답(labels_human.jsonl)이 있는 공지를 방·정답 종류로 층화해 5겹으로 나누고 씨앗 5개로 반복한다.
# 겹마다 나머지 공지로만 학습·단어장·조기 종료·문턱값을 정하고, 채점 겹은 예측에만 쓴다.
# 기준선 측정만 한다: 모델 파일(.keras, _vocab.json)은 쓰지 않고 접힌 예측과 지표만 models/cv_*.json에 남긴다.

HUMAN_LABELS = os.path.join(DATA, "labels_human.jsonl")
CV_FOLDS = 5
CV_SEEDS = range(5)
CV_BAND = 0.05  # 캐스케이드 정책 '기타 또는 문턱 ±0.05' (backend/classifier/cascade.py BAND와 같음)
CV_METHODS = ["규칙", "Gemma", "자체", "캐스케이드"]
CV_PAIRS = [("자체", "Gemma"), ("자체", "규칙"), ("Gemma", "규칙"), ("캐스케이드", "Gemma"), ("캐스케이드", "자체")]
NON_WORD_RE = re.compile(r"\W")


def dup_key(notice):
    """거의 같은 공지를 한 묶음으로: 공백·문장부호를 뗀 본문 앞 200자. 같은 묶음은 같은 겹에 넣는다.

    여러 번 보낸 같은 공지는 전처리에서 이미 한 id로 묶였다(send_count). 이 키는 id가 다른 재공지를 잡는다.
    """
    return NON_WORD_RE.sub("", notice["text"])[:200] or notice["id"]


def tag_counts(answer, pred, tags):
    """tag_scores와 같은 정의의 한 공지 몫: (맞게 붙임, 틀리게 붙임, 놓침)."""
    a, p = set(answer) & tags, set(pred) & tags
    return len(a & p), len(p - a), len(a - p)


def prf(counts):
    hit, wrong, miss = (sum(c[k] for c in counts) for k in range(3))
    precision = hit / (hit + wrong) if hit + wrong else 0.0
    recall = hit / (hit + miss) if hit + miss else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return {"정밀도": precision, "재현율": recall, "F1": f1}


def cv_seed_metrics(rows, target, all_tags, learned):
    """씨앗 하나의 접힌 예측(사람 정답 공지마다 한 줄)으로 지표·구간·검정을 낸다. learned: {(씨앗, 겹): 배운 꼬리표}"""
    idx = list(range(len(rows)))
    if target == "category":
        hit = {m: [r[m] == r["정답"] for r in rows] for m in CV_METHODS}
        score = lambda m, s: sum(hit[m][k] for k in s) / len(s)
        out = {m: {"맞힘": sum(hit[m]), "정확도": score(m, idx), "wilson": wilson(sum(hit[m]), len(rows))}
               for m in CV_METHODS}
    else:
        tag_sets = {"전체": lambda r: all_tags, "배운": lambda r: learned[(r["seed"], r["fold"])]}
        cnt = {(m, t): [tag_counts(r["정답"], r[m], f(r)) for r in rows] for m in CV_METHODS for t, f in tag_sets.items()}
        hit = {m: [set(r[m]) == set(r["정답"]) for r in rows] for m in CV_METHODS}  # 코드 전체로 정확히 일치
        score = lambda m, s: prf([cnt[(m, "전체")][k] for k in s])["F1"]
        out = {}
        for m in CV_METHODS:
            out[m] = {**{f"{k}_코드전체": v for k, v in prf(cnt[(m, "전체")]).items()},
                      **{f"{k}_배운꼬리표": v for k, v in prf(cnt[(m, "배운")]).items()},
                      "정확히_일치": sum(hit[m]) / len(rows),
                      "F1_코드전체_구간": bootstrap_ci(idx, lambda s, m=m: score(m, s))}
    for m in CV_METHODS:
        if target == "category":
            out[m]["정확도_구간"] = bootstrap_ci(idx, lambda s, m=m: score(m, s))
    pairs = []
    for a, b in CV_PAIRS:
        only_a = sum(x and not y for x, y in zip(hit[a], hit[b]))
        only_b = sum(y and not x for x, y in zip(hit[a], hit[b]))
        pairs.append({"a": a, "b": b, "a만_맞힘": only_a, "b만_맞힘": only_b, "mcnemar_p": mcnemar_exact(only_a, only_b),
                      "차": score(a, idx) - score(b, idx),
                      "차_구간": bootstrap_ci(idx, lambda s, a=a, b=b: score(a, s) - score(b, s))})
    return {"방법": out, "쌍": pairs, "Gemma_호출": sum(r["애매"] for r in rows) / len(rows),
            "검정_기준": "정확도" if target == "category" else "관심사 코드 전체로 정확히 일치 (차·구간은 F1_코드전체)"}


def run_cv(target, unit, arch, min_count=5, epochs=60, board=False, board_weight=1.0, labels_path=HUMAN_LABELS):
    if not os.path.exists(labels_path):
        sys.exit(f"사람 정답 {labels_path}가 없어 교차 검증을 하지 않습니다.\n"
                 "make_label_sheet.py → 두 사람이 표 채우기 → label_agreement.py --merge 순서로 만든 뒤, "
                 "SHA-256을 docs/decisions.md에 적고 돌리세요.")
    with open(labels_path, "rb") as f:
        raw = f.read()
    sha256 = hashlib.sha256(raw).hexdigest()
    human = {r["id"]: r for r in map(json.loads, filter(str.strip, raw.decode("utf-8").splitlines()))}
    multi = target == "interest"
    key = "interest_ids" if multi else "category"
    name = f"cv_{target}_{unit}_{arch}" + ("_board" if board else "")

    notices = read_jsonl("notices.jsonl")
    gemma = read_jsonl("labels_gemma.jsonl")
    rule = read_jsonl("labels_rule.jsonl")
    scored = [i for i in notices if i in human and i in gemma and i in rule]  # 채점 대상
    unknown = sorted(set(human) - set(notices))
    pool = [i for i in notices if i in gemma]  # 학습에 쓸 수 있는 알림톡 (채점 겹은 겹마다 뺀다)
    group = {i: dup_key(n) for i, n in notices.items()}

    # 게시판 보강분: 학습 세트에만 보탠다 (알림톡과 id가 겹치지 않음: 'mjc_www_*:' 접두)
    all_notices, all_gemma, board_ids = notices, gemma, []
    if board:
        board_notices, board_labels = read_jsonl("board_notices.jsonl"), read_jsonl("labels_gemma_board.jsonl")
        board_ids = [i for i in board_notices if i in board_labels]
        if set(board_ids) & set(notices):
            sys.exit("게시판 공고와 알림톡 id가 겹침")
        all_notices, all_gemma = {**notices, **board_notices}, {**gemma, **board_labels}

    rows, folds_info, learned = [], [], {}
    for seed in CV_SEEDS:
        folds = stratified_folds(scored, lambda i: (notices[i]["room"], human[i]["category"]), CV_FOLDS, seed,
                                 group=group.get)
        for fold in range(CV_FOLDS):
            test_ids = [i for i in scored if folds[i] == fold]
            test_groups = {group[i] for i in test_ids}
            rest = [i for i in pool if group[i] not in test_groups]  # 채점 겹과 같은 묶음은 학습에서도 뺀다
            order = np.random.default_rng(seed * CV_FOLDS + fold).permutation(len(rest))
            n_val = int(len(rest) * VAL_RATIO)
            val_ids = [rest[k] for k in order[:n_val]]
            tr_ids = [rest[k] for k in order[n_val:]]
            assert not set(test_ids) & (set(tr_ids) | set(val_ids))

            tf.keras.utils.set_random_seed(seed * CV_FOLDS + fold)
            main_fit = fit(target, unit, arch, tr_ids + board_ids, val_ids, all_notices, all_gemma, min_count, epochs,
                           frozenset(board_ids), board_weight)
            probs = main_fit.model.predict(main_fit.to_x(test_ids), verbose=0)
            # 캐스케이드의 '애매'는 운영과 같이 관심사 모델이 판단한다 (종류를 채점할 때도 관심사 모델을 따로 학습)
            if multi:
                inter, inter_probs = main_fit, probs
            else:
                tf.keras.utils.set_random_seed(seed * CV_FOLDS + fold)
                inter = fit("interest", unit, arch, tr_ids, val_ids, notices, gemma, min_count, epochs)
                inter_probs = inter.model.predict(inter.to_x(test_ids), verbose=0)
            n_tags = len(inter.classes)
            learned[(seed, fold)] = set(inter.classes)

            for k, i in enumerate(test_ids):
                tag_p, other_p = inter_probs[k, :n_tags], float(inter_probs[k, n_tags])
                unsure = bool(other_p >= inter.other_threshold or (np.abs(tag_p - inter.threshold) < CV_BAND).any())
                if multi:
                    mine = [t for t, p in zip(inter.classes, tag_p) if p >= inter.threshold]
                    p_out = {**{t: round(float(p), 4) for t, p in zip(inter.classes, tag_p)}, OTHER: round(other_p, 4)}
                else:
                    mine = main_fit.classes[int(np.argmax(probs[k]))]
                    p_out = {c: round(float(p), 4) for c, p in zip(main_fit.classes, probs[k])}
                rows.append({"id": i, "seed": seed, "fold": fold, "정답": human[i][key], "규칙": rule[i][key],
                             "Gemma": gemma[i][key], "자체": mine, "캐스케이드": gemma[i][key] if unsure else mine,
                             "애매": unsure, "확률": p_out})
            folds_info.append({
                "seed": seed, "fold": fold, "train": len(tr_ids), "board": len(board_ids), "val": len(val_ids),
                "test": len(test_ids), "배운_꼬리표": inter.classes, "뺀_꼬리표": inter.dropped,
                "threshold": inter.threshold, "other_threshold": inter.other_threshold,
                **({} if multi else {"종류_코드": main_fit.classes}),
            })

    all_tags = all_interest_codes()
    per_seed = {s: cv_seed_metrics([r for r in rows if r["seed"] == s], target, all_tags, learned) for s in CV_SEEDS}
    point = [k for k, v in per_seed[0]["방법"]["자체"].items() if isinstance(v, float)]
    mean = {m: {k: float(np.mean([per_seed[s]["방법"][m][k] for s in CV_SEEDS])) for k in point} for m in CV_METHODS}
    mean["Gemma_호출"] = float(np.mean([per_seed[s]["Gemma_호출"] for s in CV_SEEDS]))
    info = {"name": name, "target": target, "labels_file": os.path.basename(labels_path), "labels_sha256": sha256,
            "folds": CV_FOLDS, "seeds": list(CV_SEEDS), "band": CV_BAND, "scored": len(scored),
            "predictions": len(rows), "labels_not_in_notices": unknown, "mean": mean,
            "per_seed": {str(s): v for s, v in per_seed.items()}, "fold_info": folds_info, "rows": rows}
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, f"{name}.json"), "w", encoding="utf-8") as f:
        json.dump(info, f, ensure_ascii=False, indent=1, default=list)
    print_cv_report(info)
    return info


def print_cv_report(info):
    print(f"\n== {info['name']}  (사람 정답 {info['scored']}건 × 씨앗 {len(info['seeds'])}개 = 예측 {info['predictions']}건)")
    print(f"사람 정답 {info['labels_file']} SHA-256 {info['labels_sha256']}")
    if info["labels_not_in_notices"]:
        print(f"notices.jsonl에 없어 뺀 사람 정답 {len(info['labels_not_in_notices'])}건")
    learned = sorted({t for f in info["fold_info"] for t in f["배운_꼬리표"]})
    print(f"겹마다 배운 관심사 꼬리표 (학습 예시 5건 이상): 합쳐서 {learned}")
    cols = [k for k in info["mean"]["자체"]]
    print("\n씨앗 평균".ljust(14) + "".join(c.rjust(18) for c in cols))
    for m in CV_METHODS:
        print(m.ljust(14) + "".join(f"{info['mean'][m][c]:.3f}".rjust(18) for c in cols))
    print(f"Gemma 호출 비율 평균 {info['mean']['Gemma_호출']:.1%}")
    s0 = info["per_seed"]["0"]
    print(f"\n씨앗 0 구간·검정 ({s0['검정_기준']})")
    for m, v in s0["방법"].items():
        ci = v.get("wilson") or v["F1_코드전체_구간"]
        print(f"  {m:6} 95% 구간 {ci[0]:.3f} ~ {ci[1]:.3f}")
    for p in s0["쌍"]:
        print(f"  {p['a']} vs {p['b']}: {p['a만_맞힘']} 대 {p['b만_맞힘']}, McNemar p {p['mcnemar_p']:.3f}, "
              f"차 {p['차']:+.3f} ({p['차_구간'][0]:+.3f} ~ {p['차_구간'][1]:+.3f})")
    print(f"\n저장: models/{info['name']}.json (접힌 예측 전체, 씨앗별 지표)")


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
    ap.add_argument("--cv", action="store_true",
                    help="사람 정답(labels_human.jsonl)으로 채점하는 5겹 × 씨앗 5개 교차 검증. 모델 파일은 쓰지 않는다")
    ap.add_argument("--labels", default=HUMAN_LABELS, help="--cv의 사람 정답 파일 (기본 processed/labels_human.jsonl)")
    args = ap.parse_args()
    board = args.board

    if args.cv:
        run_cv(args.target, args.unit, args.arch, args.min_count, args.epochs, board, args.board_weight, args.labels)
        return
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
