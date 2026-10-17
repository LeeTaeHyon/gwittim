"""규칙 기반 분석기: 결정적 파싱만으로 RawNotice에서 구조화 정보를 뽑는다.

LLM 분석기(W8 이후)는 같은 Analyzer 인터페이스로 교체·보강한다. 규칙 분석기는 스스로 추출이 완전하다고
판단할 근거가 약하므로, 첨부·미해석 조건·조건 미발견이 있으면 extraction_complete=false로 둔다.
"""
from __future__ import annotations

import json
import re
from functools import cache
from pathlib import Path
from typing import Protocol

from backend.contracts import CONTRACTS_DIR
from backend.sources import SourceConfig

from .dates import date_info, parse_line

ANALYSIS_VERSION = "rule-0.1"


class Analyzer(Protocol):
    version: str

    def analyze(self, raw: dict, source: SourceConfig) -> dict:
        """Notice 분석 필드(category, tags, 날짜, eligibility, summary)를 돌려준다."""
        ...


# ---------- 사전 ----------

@cache
def _dictionary(name: str) -> list[dict]:
    path: Path = CONTRACTS_DIR / "dictionaries" / f"{name}.json"
    return json.loads(path.read_text(encoding="utf-8"))["items"]


# ---------- 키워드 표 (제목 우선, 첫 일치) ----------

CATEGORY_RULES = [
    ("contest", r"공모전|경진대회|해커톤|대회"),
    ("scholarship", r"장학"),
    ("internship", r"인턴|현장실습"),
    ("job", r"채용|구인"),
    ("volunteer", r"봉사"),
    ("global", r"해외|연수|교환학생|유학"),
    ("startup", r"창업"),
    ("extracurricular", r"비교과|마일리지|역량"),
    ("education_program", r"교육생|특강|강좌|과정|교육"),
    ("event", r"행사|박람회|축제|설명회|포럼|바자회"),
    ("academic", r"수강|학사|성적|졸업|등록금|강의평가|시험"),
]

INTEREST_RULES = {
    "ai_data": r"\bAI\b|인공지능|데이터",
    "software": r"소프트웨어|개발자|코딩|프로그래밍|SW",
    "security": r"보안",
    "electronics_hw": r"전자|반도체|하드웨어|전기",
    "mechanical_manufacturing": r"기계|제조|생산",
    "construction_spatial": r"건설|토목|공간정보|드론",
    "design": r"디자인",
    "media_content": r"영상|미디어|콘텐츠",
    "business_marketing": r"마케팅|경영|비즈니스",
    "finance_accounting": r"금융|회계|세무",
    "startup": r"창업",
    "global_language": r"해외|외국어|어학|글로벌|유학",
    "education_welfare": r"유아교육|사회복지|상담",
    "health": r"보건|의료",
    "culture_arts": r"문화|예술|공연|음악|문학|글쓰기",
    "sports": r"스포츠|체육",
    "public_service": r"공공기관|행정|공무원",
    "volunteering": r"봉사",
}

ROLE_RULES = {
    "software_developer": r"개발자|소프트웨어 개발|백엔드|프론트엔드",
    "data_ai": r"데이터 (?:분석|엔지니어)|AI 엔지니어",
    "security_engineer": r"보안 (?:엔지니어|전문)",
    "designer": r"디자이너",
    "marketer": r"마케터|마케팅 (?:직무|담당)",
    "accountant": r"회계|세무사무",
    "entrepreneur": r"창업",
    "content_creator": r"콘텐츠 제작|영상 제작|크리에이터",
    "office_admin": r"사무원|경영지원|행정 (?:직원|보조)",
}

START_DEADLINE = re.compile(r"신청\s*기간|접수\s*기간|모집\s*기간|공모\s*기간|원서\s*접수|신청\s*기한|접수\s*기한|제출\s*기한|마감|까지")
ACTIVITY = re.compile(r"활동\s*기간|교육\s*기간|운영\s*기간|행사\s*기간|연수\s*기간")
NOTE = re.compile(r"선착순|예산\s*소진|조기\s*마감")

GRADE_RANGE = re.compile(r"([1-4])\s*[~\-–]\s*([1-4])\s*학년")
GRADE_LIST = re.compile(r"([1-4])\s*[,·]\s*([1-4])\s*학년")
GRADE_ONE = re.compile(r"(?<![~\-–,·\d])([1-4])\s*학년\s*(?:만|대상|재학생|학생)")
UNIVERSITY = re.compile(r"우리\s*대학|본교")
UNRESTRICTED = re.compile(r"누구나|제한\s*없|학년\s*무관|전공\s*무관")
UNRESOLVED = re.compile(r"평점|학점|성적|소득|연령|나이|만\s*\d+\s*세|우대|요건")
SEE_ATTACHMENT = re.compile(r"(?:첨부|붙임|모집요강)[^\n]{0,10}참(?:조|고)")


def _lines(raw: dict) -> list[str]:
    return [line.strip() for line in raw["body_text"].splitlines() if line.strip()]


def _codes(rules: dict[str, str], text: str, allowed: set[str]) -> list[str]:
    return [code for code, pattern in rules.items() if code in allowed and re.search(pattern, text)]


class RuleBasedAnalyzer:
    version = ANALYSIS_VERSION

    def analyze(self, raw: dict, source: SourceConfig) -> dict:
        title, lines = raw["title"], _lines(raw)
        text = title + "\n" + "\n".join(lines)
        return {
            "summary": None,  # 검증된 요약은 LLM 단계 이후
            "category": self._category(title, text),
            "interest_tags": _codes(INTEREST_RULES, text, {i["id"] for i in _dictionary("interests")}),
            "related_majors": [m["id"] for m in _dictionary("majors") if m["name_ko"] in text],
            "related_roles": _codes(ROLE_RULES, text, {r["id"] for r in _dictionary("roles")}),
            **self._dates(lines, source),
            "eligibility": self._eligibility(raw, lines, source),
        }

    @staticmethod
    def _category(title: str, text: str) -> str:
        for target in (title, text):
            for code, pattern in CATEGORY_RULES:
                if re.search(pattern, target):
                    return code
        return "other"

    @staticmethod
    def _dates(lines: list[str], source: SourceConfig) -> dict:
        out = {"application_start": None, "application_deadline": None, "deadline_note": None, "activity_period": None}
        tz = source.timezone
        for line in lines:
            if out["deadline_note"] is None and NOTE.search(line):
                out["deadline_note"] = line
            start, end = parse_line(line)
            if start is None:
                continue
            if out["application_deadline"] is None and START_DEADLINE.search(line):
                if end:
                    out["application_start"] = date_info(start, line, tz)
                    out["application_deadline"] = date_info(end, line, tz)
                else:
                    out["application_deadline"] = date_info(start, line, tz)
            elif out["activity_period"] is None and ACTIVITY.search(line):
                out["activity_period"] = {
                    "start": date_info(start, line, tz),
                    "end": date_info(end, line, tz) if end else None,
                    "evidence": line,
                }
        return out

    @staticmethod
    def _eligibility(raw: dict, lines: list[str], source: SourceConfig) -> dict:
        conditions, unresolved = [], []
        majors = _dictionary("majors")

        def add(field, operator, value, evidence):
            if not any(c["field"] == field for c in conditions):
                conditions.append({"field": field, "operator": operator, "value": value, "evidence": evidence, "validation_status": "validated"})

        unrestricted_line = None
        for line in lines:
            if m := GRADE_RANGE.search(line):
                lo, hi = sorted((int(m[1]), int(m[2])))
                add("grade", "in", list(range(lo, hi + 1)), line)
            elif m := GRADE_LIST.search(line):
                add("grade", "in", sorted({int(m[1]), int(m[2])}), line)
            elif m := GRADE_ONE.search(line):
                add("grade", "eq", int(m[1]), line)

            statuses = [s for s, p in (("enrolled", r"재학생"), ("on_leave", r"휴학생"), ("graduated", r"졸업생|졸업자")) if re.search(p, line)]
            if statuses:
                add("enrollment_status", "eq" if len(statuses) == 1 else "in", statuses[0] if len(statuses) == 1 else statuses, line)

            if source.university_id and UNIVERSITY.search(line):
                add("university_id", "eq", source.university_id, line)

            named = [m["id"] for m in majors if m["name_ko"] in line and re.search(re.escape(m["name_ko"]) + r"\s*(?:재학생|학생|대상|소속)", line)]
            if named:
                add("major_id", "eq" if len(named) == 1 else "in", named[0] if len(named) == 1 else named, line)

            if UNRESOLVED.search(line) or SEE_ATTACHMENT.search(line):
                unresolved.append({"evidence": line, "note": None})
            if unrestricted_line is None and UNRESTRICTED.search(line):
                unrestricted_line = line

        explicit = unrestricted_line is not None and not conditions
        complete = (
            (bool(conditions) or explicit)
            and not unresolved
            and not raw["attachments"]
            and not raw["source_fields"].get("body_image_count")  # 포스터 이미지 속 조건은 읽지 못함
        )
        return {
            "conditions": conditions,
            "unresolved_conditions": unresolved,
            "extraction_complete": complete,
            "explicitly_unrestricted": explicit,
            "unrestricted_evidence": unrestricted_line if explicit else None,
        }
