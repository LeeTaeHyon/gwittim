"""알림톡 분류 캐스케이드: 내 모델이 먼저 분류하고, 배운 적 없는 분야 같으면 관심사만 Gemma에 넘긴다 (D-019, D-035).

두 모델 모두 사람 정답(D-033)으로 학습했다. 교차 검증(287건, 5겹 × 씨앗 5)에서
  · 종류: 내 모델 0.831, Gemma 0.477. 애매할 때 Gemma로 바꾸면 0.814 → 종류는 항상 내 모델 답 (D-037: 드문 종류 가중치)
  · 관심사 F1: 내 모델 0.800, Gemma 0.647. 예전 정책('기타 또는 문턱 ±0.05')으로 넘기면 0.734로 떨어진다.
    Gemma가 사람보다 꼬리표를 넓게 붙이기 때문이다.
그래서 애매함은 '기타' 확률 ≥ 기타 문턱 하나다(모델이 배운 4개 밖의 분야일 수 있음). 이 정책은 F1 0.796, Gemma 호출 0.6%.
Gemma가 없거나 실패하면 내 모델 결과를 쓴다.
"""
from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field

from . import gemma_tags
from .text_model import TextModel, text_of

# 모델·문턱·캐스케이드 정책이 바뀌면 올린다 (분석 버전에 붙어 재분석을 일으킴)
# 0.2: 종류·관심사 모델을 사람 정답 학습으로 교체, 종류는 Gemma로 바꾸지 않음, Gemma는 '기타'일 때만 (D-035)
# 0.3: 종류 모델을 드문 종류 가중치로 다시 학습, 사람 정답 6건 정정 (D-037)
MODEL_VERSION = "kakao-0.3"
INTEREST_MODEL = "interest_char_avg_human"
CATEGORY_MODEL = "category_char_avg_board_human"
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
    if other_p >= interest.other_threshold:  # 배운 꼬리표 밖의 분야일 수 있음
        unsure.append(f"{OTHER} {other_p:.2f} ≥ {interest.other_threshold}")

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
            result.interest_ids, result.source = g["interest_ids"], "gemma"  # 종류는 내 모델 답 그대로
    return result
