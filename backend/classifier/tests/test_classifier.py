"""표준 라이브러리 추론이 Keras와 같은 값을 내는지, 캐스케이드가 정책대로 Gemma를 부르는지 확인한다 (D-019)."""
import json

import pytest

from backend.classifier import cascade
from backend.classifier.text_model import ASCII_LOWER, MODEL_DIR, TextModel

MODELS = [cascade.INTEREST_MODEL, cascade.CATEGORY_MODEL]


@pytest.mark.parametrize("name", MODELS)
def test_matches_keras_on_check_texts(name):
    # export_weights.py가 Keras로 계산해 저장한 확률
    meta = json.loads((MODEL_DIR / f"{name}.json").read_text(encoding="utf-8"))
    model = TextModel.load(name)
    assert meta["check"]
    for case in meta["check"]:
        assert model.probs(case["text"]) == pytest.approx(case["probs"], abs=1e-5)


def test_tokens_follow_keras_standardize():
    model = TextModel.load(cascade.CATEGORY_MODEL)
    # ASCII만 소문자로 바꾸고 문장부호는 지운 뒤 글자 하나씩 나눈다
    assert model.tokens("AI, 특강!") == model.tokens("ai 특강")
    assert "AⅡ".translate(ASCII_LOWER) == "aⅡ"  # 로마 숫자는 소문자로 바꾸지 않는다 (tf.strings.lower와 같음)
    assert len(model.tokens("가" * 1000)) == model.seq_len  # 학습 때 길이까지만 본다


def test_cascade_calls_gemma_only_when_unsure(monkeypatch):
    calls = []

    def gemma(title, text):
        calls.append(title)
        return {"interest_ids": ["culture_arts"], "category": "contest", "for_all_students": True, "reason": ""}

    texts = ["[합성] 도서관 독서 감상문 공모전 안내", "[합성] 2026 AI 데이터 분석 특강 수강생 모집 파이썬 머신러닝 실습"]
    results = [cascade.classify(t, t, gemma) for t in texts]
    for r in results:
        if r.unsure:
            assert r.source == "gemma" and r.interest_ids == ["culture_arts"]
        else:
            assert r.source == "model"
    assert len(calls) == sum(bool(r.unsure) for r in results)

    # 애매함 기준: 기타 확률이 문턱 이상이거나 꼬리표 확률이 문턱 ± BAND 안
    interest = TextModel.load(cascade.INTEREST_MODEL)
    for r in results:
        near = any(abs(p - interest.threshold) < cascade.BAND for p in r.interest_probs.values())
        assert bool(r.unsure) == (near or r.other_prob >= interest.other_threshold)


def test_model_only_without_gemma():
    r = cascade.classify("[합성] 영어 회화 어학 프로그램", "TOEIC 대비반", None)
    assert r.source == "model"
    assert set(r.interest_ids) <= {"ai_data", "global_language", "media_content"}
