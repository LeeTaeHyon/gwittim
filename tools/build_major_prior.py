"""학과 → 직무·관심사 통계 확률표를 만든다 (D-017, 목표 2 방식 A).

커리어넷 학과정보의 두 자료를 합친다.
- 졸업 후 첫 직업분야 비율 (한국고용정보원 대졸자 직업이동 경로조사 2020, 직업 대분류 10개, 계열 단위)
- 관련직업 목록 (학과마다 2~22개)

P(직무 | 학과) = Σ_분야 P(분야 | 학과) × P(직무 | 분야, 학과)
  P(직무 | 분야, 학과): 그 분야에 속한 직무 중 관련직업에 많이 나온 직무에 더 준다 (스무딩 포함).
P(관심사 | 학과) = 직무 확률을 관심사로 옮긴 것과 관련직업 키워드 비율의 평균.

입력: data/careernet_majors.json (커리어넷 학과정보 웹 페이지에서 옮겨 적은 원자료, 커밋하지 않음)
  커리어넷 학과정보 글은 공공누리 제4유형(출처 표시·비상업·변경 금지)이라 원문은 저장소·앱에 싣지 않고,
  계산한 확률만 출처와 함께 싣는다.
출력: contracts/stats/major_prior.json (백엔드 추천 점수와 앱 프로필 화면이 함께 쓴다)

실행: uv run python -m tools.build_major_prior [--source data/careernet_majors.json]
"""
from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "data/careernet_majors.json"
OUTPUT = ROOT / "contracts/stats/major_prior.json"

# 커리어넷 직업 대분류 → 우리 직무 사전(contracts/dictionaries/roles.json). 농림어업직은 대응 직무 없음.
FIELD_ROLES = {
    "경영·사무·금융·보험직": ("office_admin", "accountant", "marketer"),
    "연구직 및 공학 기술직": (
        "software_developer",
        "data_ai",
        "security_engineer",
        "hw_engineer",
        "mechanical_engineer",
        "civil_engineer",
    ),
    "교육·법률·사회복지·경찰·소방직 및 군인": ("educator", "social_worker", "public_official"),
    "보건·의료직": ("healthcare",),
    "예술·디자인·방송·스포츠직": ("designer", "content_creator", "artist"),
    "미용·여행·숙박·음식·경비·청소직": ("service",),
    "영업·판매·운전·운송직": ("marketer", "service"),
    "건설·채굴직": ("civil_engineer",),
    "설치·정비·생산직": ("mechanical_engineer", "hw_engineer"),
    "농림어업직": (),
}

# 대분류 이름이 곧 그 직무인 경우의 대표 직무. 관련직업에 안 나와도 기본으로 1을 더 준다.
# 예: 행정학과 관련직업이 세무사·회계사뿐이어도 '경영·사무직' 졸업자는 대부분 사무직이다.
FIELD_BASE_ROLE = {"경영·사무·금융·보험직": "office_admin"}

# 관련직업 이름 → 직무. 한 직업이 여러 직무에 걸릴 수 있다.
# 직무 사전에 스포츠가 없어 운동선수·심판 등은 같은 대분류(예술·디자인·방송·스포츠직)의 artist로 둔다.
ROLE_JOB_PATTERNS = {
    "software_developer": r"개발자|프로그래머|소프트웨어|IT컨설턴트|가상현실|사물인터넷|정보시스템",
    "data_ai": r"데이터|인공지능|정보분석",
    "security_engineer": r"보안|정보보호|사이버안전",
    "hw_engineer": r"전자|전기|반도체|통신|네트워크|스마트그리드|발전장치|방송장비|무인자동차",
    "mechanical_engineer": r"기계|금형|용접|정비원|생산관리|품질관리|3D프린팅|드론|무인항공기|기관사|비파괴",
    "civil_engineer": r"토목|건설|측량|도시설계|지적|콘크리트|캐드",
    "designer": r"디자이너|디자인|일러스트|컬러리스트|머천다이저|패턴사|한복사|세공|애니메이터|코디네이터",
    "content_creator": r"작가|PD|연출|콘텐츠|촬영|방송|카피라이터|출판|편집|웹프로듀서|성우|조명|스크립터|기자",
    "marketer": r"광고|홍보|마케팅|시장조사|무역|영업|네이미스트|전자상거래",
    "office_admin": r"사무원|관리자|행정|경영|컨설턴트|물류|노무|운영자|부동산",
    "accountant": r"회계|세무|금융|투자|증권|펀드|보험|애널리스트|은행|관세|손해사정|외환|자산|감정평가|뱅커",
    "service": r"승무원|지상근무|호텔|여행|미용사|메이크업|피부|분장|경호|중개|체형관리|통역|번역",
    "educator": r"교사|강사|교수|지도|교육|보육|독서",
    "social_worker": r"사회복지|상담|보호관찰|청소년",
    "healthcare": r"보건|의료|병원",
    "public_official": r"공무원|공공기관|교도관|국가|정부|법무사|지방자치",
    "artist": r"가수|연주|배우|연기|댄서|작편곡|음악|극작|시인|소설|운동선수|운동감독|심판|공연|탤런트|아티스트",
}

# 직무 → 관심사(contracts/dictionaries/interests.json). service는 맞는 관심사가 없어 비운다.
ROLE_INTEREST = {
    "software_developer": "software",
    "data_ai": "ai_data",
    "security_engineer": "security",
    "hw_engineer": "electronics_hw",
    "mechanical_engineer": "mechanical_manufacturing",
    "civil_engineer": "construction_spatial",
    "designer": "design",
    "content_creator": "media_content",
    "marketer": "business_marketing",
    "office_admin": "business_marketing",
    "accountant": "finance_accounting",
    "educator": "education_welfare",
    "social_worker": "education_welfare",
    "healthcare": "health",
    "public_official": "public_service",
    "artist": "culture_arts",
    "entrepreneur": "startup",
}

# 직무로 옮겨지지 않는 관심사를 관련직업에서 직접 잡는다.
INTEREST_JOB_PATTERNS = {
    "sports": r"운동|스포츠|체육|레크리에이션|경호|트레이너|체형",
    "global_language": r"통역|번역|무역|여행|승무원|호텔|외환|관세",
    "startup": r"개인사업|창업|최고경영자",
}

# 관련직업에 한 번도 안 나온 직무에도 주는 기본값. 0이면 관련직업 목록에 없는 직무는 확률 0.
SMOOTHING = 0.2


def job_roles(job: str) -> set[str]:
    return {role for role, pattern in ROLE_JOB_PATTERNS.items() if re.search(pattern, job)}


def job_interests(job: str) -> set[str]:
    found = {ROLE_INTEREST[r] for r in job_roles(job) if r in ROLE_INTEREST}
    return found | {i for i, pattern in INTEREST_JOB_PATTERNS.items() if re.search(pattern, job)}


def _normalize(weights: dict[str, float]) -> dict[str, float]:
    total = sum(weights.values())
    if total == 0:
        return {}
    return {k: round(v / total, 4) for k, v in sorted(weights.items(), key=lambda kv: -kv[1]) if v > 0}


def role_prior(first_job_field: dict[str, float], relate_jobs: list[str]) -> dict[str, float]:
    counts = Counter(role for job in relate_jobs for role in job_roles(job))
    weights: dict[str, float] = {}
    for field, pct in first_job_field.items():
        roles = FIELD_ROLES[field]
        if not roles or pct == 0:
            continue
        inner = {r: counts[r] + SMOOTHING + (1 if FIELD_BASE_ROLE.get(field) == r else 0) for r in roles}
        inner_total = sum(inner.values())
        for role, w in inner.items():
            weights[role] = weights.get(role, 0.0) + pct * w / inner_total
    return _normalize(weights)


def interest_prior(roles: dict[str, float], relate_jobs: list[str]) -> dict[str, float]:
    from_roles: dict[str, float] = {}
    for role, p in roles.items():
        if role in ROLE_INTEREST:
            i = ROLE_INTEREST[role]
            from_roles[i] = from_roles.get(i, 0.0) + p
    from_roles = _normalize(from_roles)
    from_jobs = _normalize(dict(Counter(i for job in relate_jobs for i in job_interests(job))))
    if not from_jobs:
        return from_roles
    merged = {i: 0.5 * from_roles.get(i, 0.0) + 0.5 * from_jobs.get(i, 0.0) for i in from_roles.keys() | from_jobs.keys()}
    return _normalize(merged)


def build(source: dict) -> dict:
    majors = {}
    for major_id, m in source["majors"].items():
        roles = role_prior(m["first_job_field"], m["relate_jobs"])
        majors[major_id] = {
            "careernet_name": m["careernet_name"],
            "roles": roles,
            "interests": interest_prior(roles, m["relate_jobs"]),
        }
    return {
        "stats": "major_prior",
        "updated": source["collected"],
        "source": "커리어넷 대학교 학과정보(한국직업능력연구원)의 졸업 후 첫 직업분야 비율"
        "(한국고용정보원 대졸자 직업이동 경로조사 2020, 계열 단위)과 관련직업 목록으로 계산",
        "source_url": "https://www.career.go.kr/cloud/w/major/uList",
        "smoothing": SMOOTHING,
        "majors": dict(sorted(majors.items())),
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", type=Path, default=SOURCE)
    args = ap.parse_args()
    prior = build(json.loads(args.source.read_text(encoding="utf-8")))
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(prior, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    for major_id, p in prior["majors"].items():
        top_roles = ", ".join(f"{r} {v:.2f}" for r, v in list(p["roles"].items())[:3])
        top_interests = ", ".join(f"{i} {v:.2f}" for i, v in list(p["interests"].items())[:3])
        print(f"{major_id:34} 직무: {top_roles:60} 관심사: {top_interests}")


if __name__ == "__main__":
    main()
