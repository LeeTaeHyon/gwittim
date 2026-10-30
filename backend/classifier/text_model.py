"""학습한 Keras 모델(임베딩 → 평균 풀링 → Dense)을 TensorFlow 없이 계산한다 (D-016).

학습은 localModel/train_keras.py(Keras)에서 하고, localModel/export_weights.py가 가중치와 단어장만 꺼내
models/<이름>.json(설정·단어장) + models/<이름>.bin(float32 가중치)으로 저장한다.
서버·배치에는 TensorFlow(수백 MB)를 넣지 않고 표준 라이브러리만으로 같은 값을 낸다.

Keras 층과 대응
  TextVectorization  standardize(): ASCII 소문자 + 문장부호 제거 → split → 단어장 번호 (없으면 1, 빈칸 0)
  Embedding          번호마다 64차원 벡터 한 줄
  GlobalAvgPool1D    빈칸(0)을 뺀 토큰 벡터의 평균 (mask_zero=True)
  Dropout            예측 때는 아무것도 하지 않음
  Dense              sigmoid(관심사, 꼬리표마다 독립) 또는 softmax(카테고리, 하나만)
"""
from __future__ import annotations

import json
import math
import re
import sys
from array import array
from functools import cache
from pathlib import Path

MODEL_DIR = Path(__file__).parent / "models"
URL_RE = re.compile(r"https?://\S+")
# Keras TextVectorization 'lower_and_strip_punctuation'이 지우는 문자 (같은 정규식)
PUNCTUATION_RE = re.compile(r'[!"#$%&()\*\+,-\./:;<=>?@\[\\\]^_`{|}~\']')
# tf.strings.lower는 ASCII만 바꾼다 (str.lower는 로마 숫자·전각 문자까지 바꿔서 결과가 달라짐)
ASCII_LOWER = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")
# tf.strings.split의 공백은 ASCII 공백뿐
ASCII_SPACE_RE = re.compile(r"[ \t\n\v\f\r]+")


def text_of(title: str, body: str) -> str:
    """학습 때 모델에 넣은 글과 같은 모양 (train_keras.text_of). 링크는 단어장만 키우므로 뺀다."""
    return URL_RE.sub(" ", title + "\n" + body)


class TextModel:
    def __init__(self, meta: dict, weights: array):
        self.name = meta["name"]
        self.unit = meta["unit"]
        self.seq_len = meta["seq_len"]
        self.classes: list[str] = meta["classes"]
        self.threshold: float | None = meta["threshold"]
        self.other_threshold: float | None = meta["other_threshold"]
        self.activation = meta["activation"]
        self.index = {t: i for i, t in enumerate(meta["vocab"]) if i >= 2}  # 0 빈칸, 1 모르는 토큰
        vocab_size, self.dim = meta["embedding_shape"]
        n_out = meta["dense_shape"][1]
        if len(weights) != vocab_size * self.dim + self.dim * n_out + n_out:
            raise ValueError(f"{self.name}: 가중치 크기가 설정과 다름")
        e_end = vocab_size * self.dim
        k_end = e_end + self.dim * n_out
        self.embedding = weights[:e_end]
        self.kernel = [weights[e_end + r * n_out : e_end + (r + 1) * n_out] for r in range(self.dim)]
        self.bias = weights[k_end:]

    @classmethod
    @cache
    def load(cls, name: str) -> TextModel:
        meta = json.loads((MODEL_DIR / f"{name}.json").read_text(encoding="utf-8"))
        weights = array("f")
        weights.frombytes((MODEL_DIR / f"{name}.bin").read_bytes())
        if sys.byteorder != "little":  # 파일은 리틀 엔디언으로 저장
            weights.byteswap()
        return cls(meta, weights)

    def tokens(self, text: str) -> list[int]:
        text = PUNCTUATION_RE.sub("", text.translate(ASCII_LOWER))
        parts = list(text) if self.unit == "char" else [p for p in ASCII_SPACE_RE.split(text) if p]
        ids = [self.index.get(p, 1) for p in parts[: self.seq_len]]
        return ids  # 뒤쪽 빈칸(0)은 평균에서 빠지므로 채우지 않는다

    def probs(self, text: str) -> list[float]:
        ids = self.tokens(text)
        pooled = [0.0] * self.dim
        for t in ids:
            row = self.embedding[t * self.dim : (t + 1) * self.dim]
            for d in range(self.dim):
                pooled[d] += row[d]
        n = len(ids) or 1  # 토큰이 하나도 없으면 0 벡터
        pooled = [v / n for v in pooled]
        logits = list(self.bias)
        for d, v in enumerate(pooled):
            if v:
                for k, w in enumerate(self.kernel[d]):
                    logits[k] += v * w
        if self.activation == "softmax":
            top = max(logits)
            exps = [math.exp(z - top) for z in logits]
            total = sum(exps)
            return [e / total for e in exps]
        return [1 / (1 + math.exp(-z)) for z in logits]
