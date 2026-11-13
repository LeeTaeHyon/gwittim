"""학습한 Keras 모델에서 가중치·단어장만 꺼내 앱 배치용 파일로 저장한다 (D-019).

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
    # 특수 입력: 서로게이트 쌍 글자(이모지)
    "📢 [안내] 학생식당 운영 시간 변경 📌 자세한 내용은 아래 확인 🙏",
    "🎓🎉 졸업작품 전시회 개최 🎨 관람 환영 ✨",
    # 특수 입력: 전각 영문·숫자, 로마 숫자
    "ＡＢＣ１２３ 프로그래밍 특강 신청 안내 ＰＹＴＨＯＮ 기초반",
    "컴퓨터공학 Ⅱ 전공 심화 과정 수강생 모집, 로마 숫자 Ⅲ Ⅳ 단계 구분",
    # 특수 입력: 600자 초과 (seq_len 잘림 확인)
    "창업동아리 지원 사업 안내. " + "참가 신청서와 사업계획서를 제출 바랍니다. " * 40,
    "장학금 신청 안내 " + "성적 증명서 제출 기한을 지켜 주시기 바랍니다 " * 30 + "끝",
    # 특수 입력: 공백만, 줄바꿈·탭만, 제목·본문이 모두 빈 글의 text_of 결과(줄바꿈 하나)
    # 완전히 빈 글(""), ASCII 문장부호만 있는 글은 토큰이 0개라 Keras 평균 풀링이 NaN을 내므로 넣지 않는다
    "\n",
    "   ",
    "\n\n\t \n",
    # 특수 입력: 링크만 (text_of를 거치지 않은 원문 그대로)
    "https://example.com/notice/1234",
    "http://example.com/a/b?c=d&e=f#g",
    "신청은 https://example.com/apply 에서 하세요 https://example.org/form",
    # 특수 입력: 문장부호만
    "!!! ??? ... ,,, ;;; :::",
    "—–…·※○●◆■□▶◀",
    # 특수 입력: 단어장에 없는 글자만 (희귀 한자·기호)
    "龘龘龜龜龘",
    "☯♞ꙮᚠ∯",
    "뷁 龘 ☯ ♞",
    # 특수 입력: 영문 대소문자 혼합
    "Python Workshop for Data Science: Machine Learning, DEEP learning, And AI",
    "tOeIc sPeAkInG oPiC 대비 SPECIAL 특강 Open",
    "NOTICE: Library CLOSED on Friday, reopens MONDAY",
    # 특수 입력: 줄바꿈·탭 섞임
    "제목\t장소\t시간\n강의실 101호\t오후 2시\n\n문의: 학과 사무실",
    "[공지]\n수강신청 정정 기간\n\t월요일부터 수요일까지",
    # 일반 합성 문장: 인공지능·데이터·소프트웨어
    "인공지능 기초 스터디원 모집, 매주 수요일 저녁 비대면 진행",
    "소프트웨어 개발 해커톤 참가자 접수, 팀 구성은 2~4인",
    "데이터 시각화 도구 활용 교육 신청 안내",
    # 일반 합성 문장: 어학·글로벌
    "교환학생 파견 설명회 개최, 협정 대학 목록 안내",
    "일본어 회화 모임 신입 회원 모집",
    "외국인 유학생 한국어 멘토링 봉사자 모집",
    # 일반 합성 문장: 취업·진로
    "하반기 현장실습 학생 모집 공고, 참여 기업 목록 첨부",
    "이력서 작성과 면접 준비 특강 안내, 선착순 마감",
    "진로 상담 프로그램 신청 받습니다",
    # 일반 합성 문장: 장학·행정
    "교내 성적우수 장학금 신청 접수 안내",
    "근로장학생 선발 공고, 도서관 및 행정실 근무",
    "등록금 납부 기간 안내, 분할 납부 신청 가능",
    "수강 신청 정정 기간 변경 공지",
    # 일반 합성 문장: 공모전·대회
    "교내 포스터 디자인 공모전 개최, 주제는 지역 상생",
    "전국 대학생 아이디어 경진대회 참가자 모집",
    "영상 제작 공모전 안내, 상금 및 상장 수여",
    # 일반 합성 문장: 문화·예술·체육
    "교내 합창 동아리 정기 공연 안내, 관람 무료",
    "체육대회 종목별 참가 신청, 축구 농구 줄다리기",
    "미술 전시 관람 안내, 학생회관 로비에서 진행",
    # 일반 합성 문장: 창업·경영·마케팅
    "창업 아이디어 발표회 참가팀 모집, 멘토링 제공",
    "마케팅 실무 특강 개최, 사례 중심 강의",
    "경영학과 졸업생 초청 선배와의 대화 행사",
    # 일반 합성 문장: 봉사·생활·시설
    "사회봉사 프로그램 참여 학생 모집, 봉사 시간 인정",
    "기숙사 입사 신청 안내, 선발 기준과 일정 공지",
    "학생 건강 검진 일정 및 장소 안내",
    "셔틀버스 운행 시간표 개편 안내",
]


def keras_probs(model, vocab, seq_len, texts):
    tok = layers.TextVectorization(split="character", output_sequence_length=seq_len, vocabulary=vocab[2:])
    return model.predict(tok(texts).numpy(), verbose=0)


def decide(p, activation, meta):
    if activation == "softmax":
        return p.argmax(axis=1).reshape(-1, 1)
    return p[:, : len(meta["classes"])] >= meta["threshold"]


def compare(name, model, meta):
    """저장된 파일로 만든 TextModel과 Keras 원본을 notices.jsonl 전부로 비교. (판정 일치 수, 전체 수, 최대 확률 차)"""
    mine = TextModel.load(name)
    with open(os.path.join(DATA, "notices.jsonl"), encoding="utf-8") as f:
        texts = [text_of(n["title"], n["text"]) for n in map(json.loads, f)]
    p_keras = keras_probs(model, meta["vocab"], meta["seq_len"], texts)
    p_mine = np.array([mine.probs(t) for t in texts])
    activation = model.layers[-1].get_config()["activation"]
    same = int((decide(p_mine, activation, meta) == decide(p_keras, activation, meta)).all(axis=1).sum())
    return same, len(texts), float(np.abs(p_mine - p_keras).max())


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
    same, total, diff = compare(name, model, meta)
    size_kb = round((os.path.getsize(MODEL_DIR / f"{name}.bin") + os.path.getsize(MODEL_DIR / f"{name}.json")) / 1024)
    print(f"{name}: {size_kb}KB, 글자 {len(vocab)}개")
    print(f"  표준 라이브러리 vs Keras: 최대 확률 차 {diff:.2e}, 판정 일치 {same}/{total}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="+", default=DEFAULT_MODELS)
    args = ap.parse_args()
    for name in args.models:
        export(name)


if __name__ == "__main__":
    main()
