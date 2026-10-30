"""알림톡 분석기 (D-019): 날짜·조건·요약은 기존 분석기, 카테고리·관심사는 학습한 모델 + Gemma 캐스케이드.

게시판 공고(mjc_www_*)에는 쓰지 않는다. 모델은 알림톡으로만 학습·평가했다.

알림톡은 날짜에 연도를 거의 쓰지 않아 기존 분석기가 마감·행사일을 못 찾는다. 기존 분석기가 비워 둔 칸만
발송일 기준으로 다시 읽는다 (dates.points_near).
- 신청 마감: '까지'·'마감'·'신청 기간' 줄의 날짜. 여러 프로그램을 묶은 안내가 많아 가장 늦은 날짜를 쓴다
  (앞 프로그램 마감으로 아직 열린 안내가 닫히지 않게).
- 활동 기간: 그 밖의 날짜(특강·검사·행사일). 처음 ~ 마지막 날짜. 마감일이 없을 때 끝난 공고 판단에 쓴다.
"""
from __future__ import annotations

from collections import Counter
from datetime import date

from backend.classifier.cascade import MODEL_VERSION, GemmaFn, classify
from backend.sources import SourceConfig

from .dates import date_info, points_near
from .rules import START_DEADLINE, Analyzer, RuleBasedAnalyzer, is_activity_line


# 알림톡 날짜 보강 규칙 버전. 바꾸면 올린다 (분석 버전에 붙어 재분석을 일으킴)
DATES_VERSION = "kdate-0.1"


class KakaoAnalyzer:
    def __init__(self, base: Analyzer | None = None, gemma: GemmaFn | None = None):
        self.base = base or RuleBasedAnalyzer()
        self.gemma = gemma
        self.version = f"{self.base.version}+{MODEL_VERSION}+{DATES_VERSION}"
        self.decided_by: Counter[str] = Counter()  # 이번 실행에서 누가 분류했는지 (배치 요약용)

    def analyze(self, raw: dict, source: SourceConfig) -> dict:
        fields = self.base.analyze(raw, source)
        base_version = fields.pop("_analysis_version", self.base.version)
        if raw.get("published"):
            fill_dates(fields, raw, source.timezone)
        c = classify(raw["title"], raw["body_text"], self.gemma)
        self.decided_by[c.source] += 1
        fields["category"] = c.category
        if c.category == "admin_notice":  # 학생 대상이 아닌 공지는 꼬리표 없이 게시 (SPEC §6 추천 1)
            fields.update(interest_tags=[], related_majors=[], related_roles=[])
        else:
            fields["interest_tags"] = c.interest_ids
        # 기존 분석기가 LLM 실패로 규칙 결과를 냈거나 애매한데 Gemma를 못 불렀으면 다른 버전으로 기록한다.
        # 분석기 버전과 달라서 다음 배치 때 다시 분석된다 (build_notice의 재사용 조건)
        version = f"{base_version}+{MODEL_VERSION}+{DATES_VERSION}" + ("-nogemma" if c.source == "model_gemma_failed" else "")
        if version != self.version:
            fields["_analysis_version"] = version
        return fields


def fill_dates(fields: dict, raw: dict, timezone: str | None) -> None:
    """기존 분석기가 비워 둔 신청 마감·활동 기간을 발송일 기준 날짜로 채운다. 근거는 원문 줄 그대로."""
    anchor = date.fromisoformat(raw["published"]["date"])
    deadlines, events = [], []
    for line in [raw["title"], *raw["body_text"].splitlines()]:
        points = points_near(line, anchor)
        if not points:
            continue
        if START_DEADLINE.search(line) and not is_activity_line(line):
            deadlines.append((max(points, key=lambda p: p.day), line))  # 범위면 끝 날짜
        else:
            events += [(p, line) for p in points]
    if fields["application_deadline"] is None and deadlines:
        point, line = max(deadlines, key=lambda d: d[0].day)
        fields["application_deadline"] = date_info(point, line, timezone)
    if fields["activity_period"] is None and events:
        (first, first_line), (last, last_line) = min(events, key=lambda e: e[0].day), max(events, key=lambda e: e[0].day)
        fields["activity_period"] = {
            "start": date_info(first, first_line, timezone),
            "end": date_info(last, last_line, timezone) if last.day != first.day else None,
            "evidence": first_line,
        }
