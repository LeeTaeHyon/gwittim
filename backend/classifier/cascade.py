"""알림톡 분류 캐스케이드: 내 모델이 먼저 분류하고, 애매하면 Gemma에 넘긴다 (D-016).

애매함 (localModel/train_keras.py 시험 세트 비교의 '기타 또는 문턱 ±0.05' 정책)
  · 기타 확률 ≥ 기타 문턱: 배운 적 없는 분야일 수 있음 (모델은 관심사 18개 중 3개만 배웠다)
  · 꼬리표 확률이 문턱 ± BAND 안: 붙일지 말지 경계
사람 검수 47건에서 Gemma 호출 26%로 Gemma만 쓸 때와 같은 F1(0.68)을 냈다.
Gemma가 없거나 실패하면 내 모델 결과를 쓴다.
"""
from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field

from . import gemma_tags
from .text_model import TextModel, text_of

MODEL_VERSION = "kakao-0.1"  # 모델·문턱·캐스케이드 정책이 바뀌면 올린다 (분석 버전에 붙어 재분석을 일으킴)
INTEREST_MODEL = "interest_char_avg"
CATEGORY_MODEL = "category_char_avg_board"
BAND = 0.05
OTHER = "기타"


@dataclass
class Classification:
    interest_ids: list[str]
    category: str
    source: str  # "model" | "gemma" | "model_gemma_failed"
    unsure: list[str] = field(default_factory=list)  # 애매하다고 본 이유
    interest_probs: dict[str, float] = field(default_factory=dict)
    other_prob: float | None = None


GemmaFn = Callable[[str, str], dict]  # (제목, 본문) → gemma_tags.validate 결과


def ollama(model: str = "gemma4:12b", host: str = "http://127.0.0.1:11434", timeout: float = 180) -> GemmaFn:
    return lambda title, text: gemma_tags.validate(gemma_tags.chat(model, title, text, host=host, timeout=timeout))


def classify(title: str, text: str, gemma: GemmaFn | None = None) -> Classification:
    interest, category = TextModel.load(INTEREST_MODEL), TextModel.load(CATEGORY_MODEL)
    doc = text_of(title, text)
    ip, cp = interest.probs(doc), category.probs(doc)
    n = len(interest.classes)
    tag_p, other_p = ip[:n], ip[n]

    unsure = []
    if other_p >= interest.other_threshold:
        unsure.append(f"{OTHER} {other_p:.2f} ≥ {interest.other_threshold}")
    for t, p in zip(interest.classes, tag_p):
        if abs(p - interest.threshold) < BAND:
            unsure.append(f"{t} {p:.2f} ≈ 문턱 {interest.threshold}")

    result = Classification(
        interest_ids=[t for t, p in zip(interest.classes, tag_p) if p >= interest.threshold],
        category=category.classes[cp.index(max(cp))],
        source="model",
        unsure=unsure,
        interest_probs={t: round(p, 3) for t, p in zip(interest.classes, tag_p)},
        other_prob=round(other_p, 3),
    )
    if unsure and gemma is not None:
        try:
            g = gemma(title, text)
        except Exception:  # Ollama 꺼짐·시간 초과·스키마 밖 응답 → 내 모델 결과 유지
            result.source = "model_gemma_failed"
        else:
            result.interest_ids, result.category, result.source = g["interest_ids"], g["category"], "gemma"
    return result
