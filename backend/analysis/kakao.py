"""알림톡 분석기 (D-016): 날짜·조건·요약은 기존 분석기, 카테고리·관심사는 학습한 모델 + Gemma 캐스케이드.

게시판 공고(mjc_www_*)에는 쓰지 않는다. 모델은 알림톡으로만 학습·평가했다.
"""
from __future__ import annotations

from collections import Counter

from backend.classifier.cascade import MODEL_VERSION, GemmaFn, classify
from backend.sources import SourceConfig

from .rules import Analyzer, RuleBasedAnalyzer


class KakaoAnalyzer:
    def __init__(self, base: Analyzer | None = None, gemma: GemmaFn | None = None):
        self.base = base or RuleBasedAnalyzer()
        self.gemma = gemma
        self.version = f"{self.base.version}+{MODEL_VERSION}"
        self.decided_by: Counter[str] = Counter()  # 이번 실행에서 누가 분류했는지 (배치 요약용)

    def analyze(self, raw: dict, source: SourceConfig) -> dict:
        fields = self.base.analyze(raw, source)
        base_version = fields.pop("_analysis_version", self.base.version)
        c = classify(raw["title"], raw["body_text"], self.gemma)
        self.decided_by[c.source] += 1
        fields["category"] = c.category
        if c.category == "admin_notice":  # 학생 대상이 아닌 공지는 꼬리표 없이 게시 (SPEC §6 추천 1)
            fields.update(interest_tags=[], related_majors=[], related_roles=[])
        else:
            fields["interest_tags"] = c.interest_ids
        # 기존 분석기가 LLM 실패로 규칙 결과를 냈거나 애매한데 Gemma를 못 불렀으면 다른 버전으로 기록한다.
        # 분석기 버전과 달라서 다음 배치 때 다시 분석된다 (build_notice의 재사용 조건)
        version = f"{base_version}+{MODEL_VERSION}" + ("-nogemma" if c.source == "model_gemma_failed" else "")
        if version != self.version:
            fields["_analysis_version"] = version
        return fields
