"""학습한 Keras 모델에서 가중치·단어장만 꺼내 앱 배치용 파일로 저장한다 (D-016).

출력: backend/classifier/models/<이름>.json (설정·단어장·문턱값·자체 점검 예시) + <이름>.bin (float32 가중치)
배치는 TensorFlow 없이 backend/classifier/text_model.py로 같은 계산을 한다.

글자 단위 모델만 내보낸다. 단어 단위 단어장에는 공지 속 담당자 이름·이메일이 단어로 남아 저장소에 올릴 수 없다.
내보낸 뒤 모든 알림톡으로 Keras 원본과 결과를 비교해 출력한다.

사용 (.venv의 파이썬 3.12)
  .venv/Scripts/python export_weights.py                 기본: interest_char_avg, category_char_avg_board
  .venv/Scripts/python export_weights.py --models interest_char_avg
"""
import argparse
import json
import os
import sys

import numpy as np
import tensorflow as tf
from tensorflow.keras import layers

BASE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BASE)
sys.path.insert(0, ROOT)

from backend.classifier.text_model import MODEL_DIR, TextModel, text_of  # noqa: E402
from train_keras import DATA, OUT  # noqa: E402

DEFAULT_MODELS = ["interest_char_avg", "category_char_avg_board"]
# 실제 공지가 아니라 직접 쓴 점검용 문장. 파일에 Keras 확률을 같이 저장하고 테스트가 같은 값을 내는지 본다
CHECK_TEXTS = [
    "2026 교내 AI 데이터 분석 경진대회 참가팀 모집\n파이썬에 관심 있는 재학생 누구나 신청 가능",
    "글로벌교육센터 겨울방학 영어 회화 어학 프로그램 안내 (TOEIC 대비반 포함)",
    "도서관 독서 감상문 공모전 안내 — 우수작 시상",
]


def keras_probs(model, vocab, seq_len, texts):
    tok = layers.TextVectorization(split="character", output_sequence_length=seq_len, vocabulary=vocab[2:])
    return model.predict(tok(texts).numpy(), verbose=0)


def export(name):
    with open(os.path.join(OUT, f"{name}_vocab.json"), encoding="utf-8") as f:
        meta = json.load(f)
    if meta["unit"] != "char":
        sys.exit(f"{name}: 글자 단위 모델만 내보냅니다 (단어 단위 단어장에는 이름·이메일이 남음)")
    model = tf.keras.models.load_model(os.path.join(OUT, f"{name}.keras"))
    if model.layers[1].__class__.__name__ != "GlobalAveragePooling1D":
        sys.exit(f"{name}: 평균 풀링 모델만 내보냅니다 (LSTM은 표준 라이브러리로 옮기지 않음)")
    emb = model.get_layer(index=0).get_weights()[0]
    dense = model.layers[-1]
    kernel, bias = dense.get_weights()
    activation = dense.get_config()["activation"]
    vocab = meta["vocab"]

    probs = keras_probs(model, vocab, meta["seq_len"], CHECK_TEXTS)
    out = {
        "name": name,
        "unit": meta["unit"],
        "seq_len": meta["seq_len"],
        "classes": meta["classes"],
        "threshold": meta["threshold"],
        "other_threshold": meta.get("other_threshold"),
        "activation": activation,
        "embedding_shape": list(emb.shape),
        "dense_shape": list(kernel.shape),
        "vocab": vocab,
        "check": [{"text": t, "probs": [round(float(p), 6) for p in row]} for t, row in zip(CHECK_TEXTS, probs)],
    }
    os.makedirs(MODEL_DIR, exist_ok=True)
    with open(MODEL_DIR / f"{name}.json", "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False)
    weights = np.concatenate([emb.ravel(), kernel.ravel(), bias.ravel()]).astype("<f4")
    (MODEL_DIR / f"{name}.bin").write_bytes(weights.tobytes())

    # 표준 라이브러리 구현이 Keras와 같은 판정을 내는지 모든 알림톡으로 확인
    TextModel.load.cache_clear()
    mine = TextModel.load(name)
    with open(os.path.join(DATA, "notices.jsonl"), encoding="utf-8") as f:
        texts = [text_of(n["title"], n["text"]) for n in map(json.loads, f)]
    p_keras = keras_probs(model, vocab, meta["seq_len"], texts)
    p_mine = np.array([mine.probs(t) for t in texts])

    def decide(p):
        if activation == "softmax":
            return p.argmax(axis=1).reshape(-1, 1)
        return p[:, : len(meta["classes"])] >= meta["threshold"]

    same = int((decide(p_mine) == decide(p_keras)).all(axis=1).sum())
    size_kb = round((os.path.getsize(MODEL_DIR / f"{name}.bin") + os.path.getsize(MODEL_DIR / f"{name}.json")) / 1024)
    print(f"{name}: {size_kb}KB, 글자 {len(vocab)}개")
    print(f"  표준 라이브러리 vs Keras: 최대 확률 차 {float(np.abs(p_mine - p_keras).max()):.2e}, 판정 일치 {same}/{len(texts)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="+", default=DEFAULT_MODELS)
    args = ap.parse_args()
    for name in args.models:
        export(name)


if __name__ == "__main__":
    main()
