"""Keras 원본과 표준 라이브러리 추론(backend/classifier/text_model.py)이 같은 판정을 내는지 알림톡 전부로 비교한다.

models/<이름>.keras·_vocab.json(Keras 원본)과 backend/classifier/models/<이름>.json·.bin(앱 배치용)을
notices.jsonl 전체에 돌려 모델별 판정 일치 수와 최대 확률 차를 출력한다. 파일은 쓰지 않는다.
기대: 관심사 287/287(최대 차 1e-6 미만), 종류 287/287.

사용 (.venv의 파이썬 3.12)
  .venv/Scripts/python check_parity.py                 기본: interest_char_avg, category_char_avg_board
  .venv/Scripts/python check_parity.py --models interest_char_avg
"""
import argparse
import json
import os

import tensorflow as tf

from export_weights import DEFAULT_MODELS, compare
from train_keras import OUT


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="+", default=DEFAULT_MODELS)
    args = ap.parse_args()
    for name in args.models:
        with open(os.path.join(OUT, f"{name}_vocab.json"), encoding="utf-8") as f:
            meta = json.load(f)
        model = tf.keras.models.load_model(os.path.join(OUT, f"{name}.keras"))
        same, total, diff = compare(name, model, meta)
        print(f"{name}: 판정 일치 {same}/{total}, 최대 확률 차 {diff:.2e}")


if __name__ == "__main__":
    main()
