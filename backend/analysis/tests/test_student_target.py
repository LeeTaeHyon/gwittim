"""지원 대상 문구(대학생·재학생 등) 추출 보강 (docs/student-target-extraction-spec.md §6.1, D-057).

규칙만 쓴 경우와 LLM 응답을 고정한 경우 모두, 학적 조건(value·unconfirmed_values)과 미해석 항목을 정확히 비교하고
실제 판정기로 재학·휴학·졸업 판정을 확인한다. 프로필은 명지전문대·경영학과·2학년.
"""
import pytest

from backend.analysis.tests.test_required_preferred import (  # noqa: F401  (ollama는 픽스처)
    ENROLLED2,
    c,
    llm_run,
    ollama,
    run,
)
from backend.recommendation import evaluate

BASE = {**ENROLLED2, "major_id": "mjc.business_administration"}
PROFILES = {s: {**BASE, "enrollment_status": s} for s in ("enrolled", "on_leave", "graduated")}
E, L, G = "enrolled", "on_leave", "graduated"
MET, CHECK, NOT = "met", "needs_check", "not_met"

# (id, 원문, 학적 조건 (value, unconfirmed) 또는 None, 미해석 항목 근거(note=None), 명시적 제한 없음, (재학, 휴학, 졸업))
CASES = [
    ("univ_only", "지원 대상: 대학생", ([E], [L]), [], False, (MET, CHECK, NOT)),
    ("univ_incl_leave", "지원 대상: 대학생(휴학생 포함)", ([E, L], []), [], False, (MET, MET, NOT)),
    ("univ_excl_leave", "지원 대상: 대학생(휴학생 제외)", ([E], []), [], False, (MET, NOT, NOT)),
    ("general_univ", "응모대상: 일반인, 대학생", ([E], [L, G]), [], False, (MET, CHECK, CHECK)),
    ("general_only", "응모대상: 일반인", None, ["응모대상: 일반인"], False, (CHECK, CHECK, CHECK)),
    ("site_anyone", "참가대상: 누구나, 유치원, 초등학생, 중학생, 고등학생, 대학생, 대학원생, 일반인, 외국인",
     None, [], True, (MET, MET, MET)),
    ("site_age_anyone", "참가대상: 중학생, 고등학생, 대학생, 일반인 (13세 이상 누구나)",
     ([E], [L, G]), ["13세 이상 누구나"], False, (CHECK, CHECK, CHECK)),
    ("age_nation_anyone", "18세 이상 대한민국 국민 누구나", None, ["18세 이상 대한민국 국민 누구나"], False, (CHECK, CHECK, CHECK)),
    ("adult_anyone", "성인 누구나 참여 가능", None, ["성인 누구나 참여 가능"], False, (CHECK, CHECK, CHECK)),
    ("teen_and_univ", "모집 대상: 전국 중·고등학생 및 대학생", ([E], [L]), [], False, (MET, CHECK, NOT)),
    ("univ_etc", "모집대상 : 대학생 등 자원봉사 희망자", ([E], [L, G]), [], False, (MET, CHECK, CHECK)),
    ("dept_enrolled_or_leave", "건축관련학과에 재학 또는 휴학 중인 대학생 또는 대학원생",
     ([E, L], []), ["건축관련학과에 재학 또는 휴학 중인 대학생 또는 대학원생"], False, (CHECK, CHECK, NOT)),
    ("nation_enrolled", "대한민국 국적을 소지하고 재학 중인 대학생(대학원생 제외)",
     ([E], []), ["대한민국 국적을 소지하고 재학 중인 대학생(대학원생 제외)"], False, (CHECK, NOT, NOT)),
    ("dept_enrolled_graduating", "지원 자격: 컴퓨터공학, 정보통신공학 등 관련 학과 재학생 또는 졸업예정자",
     ([E], []), ["컴퓨터공학, 정보통신공학 등 관련 학과 재학생 또는 졸업예정자"], False, (CHECK, NOT, NOT)),
    ("graduating_only", "기졸업자 또는 졸업예정자", None, ["기졸업자 또는 졸업예정자"], False, (CHECK, CHECK, CHECK)),
    ("program_name", "대학생 진로준비도검사 및 마일리지 적립 안내", None, [], False, (CHECK, CHECK, CHECK)),
    ("origin_income", "지원대상은 강화군 출신 대학생으로 소득분위 1구간부터 8구간까지입니다.",
     ([E], [L]), ["지원대상은 강화군 출신 대학생으로 소득분위 1구간부터 8구간까지입니다."], False, (CHECK, CHECK, NOT)),
    ("separate_exclusion", "재등록생, 휴학생 제외", None, ["재등록생, 휴학생 제외"], False, (CHECK, CHECK, CHECK)),
]
IDS = [case[0] for case in CASES]


def enrollment(elig):
    found = [x for x in elig["conditions"] if x["field"] == "enrollment_status"]
    if not found:
        return None
    (cond,) = found
    value = cond["value"] if isinstance(cond["value"], list) else [cond["value"]]
    return value, cond.get("unconfirmed_values", [])


def checks(elig):
    return [u["evidence"] for u in elig["unresolved_conditions"] if u["note"] is None]


def verdicts(elig):
    return tuple(evaluate(elig, p)[0] for p in PROFILES.values())


def assert_case(elig, cond, items, explicit, expected):
    assert enrollment(elig) == cond
    assert checks(elig) == items
    assert elig["explicitly_unrestricted"] is explicit
    assert verdicts(elig) == expected


@pytest.mark.parametrize("case", CASES, ids=IDS)
def test_rules_only(case):
    _, body, cond, items, explicit, expected = case
    elig, *_ = run(body)
    assert_case(elig, cond, items, explicit, expected)


@pytest.mark.parametrize("case", CASES, ids=IDS)
def test_llm_no_extra_keeps_rule_result(ollama, case):
    """LLM이 아무것도 더하지 않으면 규칙 결과와 같다."""
    _, body, cond, items, explicit, expected = case
    elig, *_ = llm_run(ollama, body, {})
    assert_case(elig, cond, items, explicit, expected)


def test_value_unconfirmed_reason_for_on_leave():
    elig, *_ = run("지원 대상: 대학생")
    status, results = evaluate(elig, PROFILES[L])
    (r,) = [x for x in results if x["field"] == "enrollment_status"]
    assert status == CHECK and r["status"] == "unknown" and r["unknown_reason"] == "value_unconfirmed"


def test_title_word_is_not_target():
    """제목·사업 이름의 '대학생'은 대상이 아니다. 본문 대상 줄만 읽는다."""
    elig, *_ = run("2026년 상반기 강화군 대학생 등록금 지원 안내\n신청 방법: 이메일 접수")
    assert enrollment(elig) is None


# LLM 경로 (§5)
def test_llm_univ_with_leave_is_moved_to_unconfirmed(ollama):
    """'대학생' 근거로 휴학까지 확인됨에 넣은 응답은 휴학을 미확인으로 옮긴다."""
    body = "■ 참가 안내\n- 공모 주제: 지역 문화"
    llm_body = body + "\n응모대상: 대학생"
    elig, *_ = llm_run(ollama, llm_body, {"conditions": [c("enrollment_status", [E, L], "응모대상: 대학생")]})
    assert enrollment(elig) == ([E], [L])
    assert verdicts(elig)[1] == CHECK


def test_llm_condition_from_program_name_is_rejected(ollama):
    body = "대학생 진로준비도검사 및 마일리지 적립 안내"
    elig, _, a = llm_run(ollama, body, {"conditions": [c("enrollment_status", [E], "대학생 진로준비도검사")]})
    assert enrollment(elig) is None
    assert any("진로준비도검사" in r for r in a.rejected)


def test_llm_general_only_is_rejected(ollama):
    body = "응모대상: 일반인"
    elig, *_ = llm_run(ollama, body, {"conditions": [c("enrollment_status", [E, L, G], "일반인")]})
    assert enrollment(elig) is None
    assert checks(elig) == ["응모대상: 일반인"]


def test_body_target_wins_over_site_category():
    """사이트 대상 칸('응모대상: 대학생')보다 본문의 자세한 대상 문구('재학생 및 휴학생')를 따른다 (원문 우선).
    본문에 대상 문구가 없으면 사이트 대상 칸을 쓴다."""
    elig, *_ = run("응모대상: 대학생, 기타\n■ 참가 자격\n- 국내 대학교 재학생 및 휴학생")
    assert enrollment(elig) == ([E, L], [])
    assert verdicts(elig) == (MET, MET, NOT)
    elig, *_ = run("응모대상: 일반인, 대학생\n■ 공모 주제\n- 지역 문화")
    assert enrollment(elig) == ([E], [L, G])


@pytest.mark.parametrize("body", [
    "모집대상: 대학생, 성인(20~30대) 자원봉사자",
    "지원 자격: 사회복지 관련 전공 대학생 및 성인",
    "모집 대상: 만 19세 이상 지역주민 및 대학생",
])
def test_non_student_alternative_leaves_graduate_unconfirmed(body):
    """성인·지역주민이 대상 하나로 나열되면 졸업생도 해당할 수 있으니 미충족이 아니라 확인 필요다."""
    elig, *_ = run(body)
    assert enrollment(elig) == ([E], [L, G])
    assert verdicts(elig)[2] == CHECK


def test_age_modifier_does_not_widen_target():
    """'재학생(만 20~69세)'처럼 숫자 나이가 대상을 꾸미면 대상을 넓히지 않는다. '주민등록'의 주민은 대상이 아니다."""
    elig, *_ = run("- 대상: 재학생(만20세~69세)")
    assert enrollment(elig) == ([E], [])
    assert verdicts(elig) == (CHECK, NOT, NOT)  # 나이는 직접 확인으로 남는다
    elig, *_ = run("지원 대상: 오산시에 주민등록이 되어 있는 대학생")
    assert enrollment(elig) == ([E], [L])


def test_staff_listed_separately_leaves_graduate_unconfirmed():
    """교직원이 재학생과 별도 대상으로 열거되면 졸업생도 교직원일 수 있으니 미충족이 아니라 확인 필요다."""
    elig, *_ = run("- 대상: 재학생 및 교직원")
    assert enrollment(elig) == ([E], [L, G])
    assert verdicts(elig) == (MET, CHECK, CHECK)


def test_conditioned_anyone_is_not_unrestricted():
    """'교사라면 누구나'처럼 조건이 붙은 '누구나'는 전체 제한 없음이 아니다. 해석할 수 없는 조건은 원문을 직접 확인으로 남긴다."""
    elig, *_ = run("지원 대상: 교사라면 누구나")
    assert elig["explicitly_unrestricted"] is False
    assert checks(elig) == ["교사라면 누구나"]
    assert verdicts(elig) == (CHECK, CHECK, CHECK)
    elig, *_ = run("관심 있는 누구나 지원 가능")  # 조건 없는 '누구나'는 그대로 제한 없음
    assert elig["explicitly_unrestricted"] is True


def test_or_age_alternative_is_evaluated_separately():
    """'대학생 또는 만 65세 이상인 자': 재학생은 대학생 자격만으로 충족하고, 졸업생은 나이로 지원할 수 있어 확인 필요다."""
    elig, *_ = run("지원 대상: 대학생 또는 만 65세 이상인 자")
    assert enrollment(elig) == ([E], [L, G])
    assert checks(elig) == []
    assert verdicts(elig) == (MET, CHECK, CHECK)
