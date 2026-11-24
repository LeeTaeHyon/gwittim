"""대학생 대상 거르기 규칙 (D-038 1차: 규칙 기반. Gemma 판별은 다음 단계).

입력은 출처 사이트가 '응모 대상'·'참가대상' 칸에 적은 글이다. 본문 속 조건은 읽지 않는다
(본문 조건은 분석 단계의 조건 판정이 맡는다).

- 포함: 대학(원)생·청년·누구나·제한 없음·일반인·성인·전체·무관이 하나라도 있으면.
  초·중·고 같은 말이 함께 있어도 포함한다(누구나 참여 공모전의 대상 칸에는 연령층이 모두 나열되는 일이 많다).
- 제외: 칸의 항목이 전부 초·중·고·청소년·어린이·유치원 같은 미성년 대상일 때만.
  이 앱의 사용자는 대학생이라 지원할 수 없는 공고를 띄우지 않기 위해서다.
- 애매하면 포함: 칸이 비었거나 '기타'·'직장인'·'외국인'처럼 위 둘에 속하지 않는 항목만 있으면 포함한다.
  대상 칸 하나로 학생을 떨어뜨리지 않고, 실제 지원 가능 여부는 분석 단계의 조건 판정이 본문 근거로 따진다.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

INCLUDE = re.compile(r"대학|청년|누구나|제한\s*없|일반(?!\s*고)|성인|전체|무관|전\s*연령")
# '청소년'에는 '청년'이 들어 있지 않다. 미성년 대상 낱말
MINOR = re.compile(r"초등|중등|중학|고등|고교|초[·ㆍ・]?중[·ㆍ・]?고|청소년|어린이|유아|유치원|영유아|아동|10대|일반고|특성화고|마이스터고")
_SPLIT = re.compile(r"[,，/|]|\s{2,}")


@dataclass(frozen=True)
class Verdict:
    include: bool
    reason: str


def audience_verdict(audience: str | None) -> Verdict:
    text = (audience or "").strip()
    if not text:
        return Verdict(True, "대상 칸 없음(애매): 포함")
    if INCLUDE.search(text):
        return Verdict(True, "대학생·일반 대상 말 있음: 포함")
    items = [t.strip() for t in _SPLIT.split(text) if t.strip()]
    if items and all(MINOR.search(t) for t in items):
        return Verdict(False, f"미성년 대상만({text[:30]}): 제외")
    return Verdict(True, f"대상 불분명({text[:30]}): 포함")
