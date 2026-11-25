"""필수 자격·우대 사항 구분 (D-056, docs/eligibility-required-preferred-spec.md §7).

원문 -> 규칙 추출 -> 실제 판정기까지 확인한다. 앱 체크리스트는 같은 결과를 담은 골든 파일
(apps/mobile/test/data/required_preferred_cases.json)로 위젯 테스트가 확인한다. 실제 LLM·외부 API는 호출하지 않는다.
골든 갱신: UPDATE_GOLDEN=1 uv run pytest backend/analysis/tests/test_required_preferred.py
"""
import json
import os
from datetime import date
from pathlib import Path

import pytest

from backend.agent import prompt as agent_prompt
from backend.analysis import RuleBasedAnalyzer, rules
from backend.analysis.llm import OllamaAnalyzer
from backend.analysis.tests.test_analysis import raw_notice
from backend.analysis.tests.test_llm import FakeOllama
from backend.recommendation import eligibility as judge
from backend.recommendation import evaluate
from backend.sources import source_config

ROOT = Path(__file__).resolve().parents[3]
GOLDEN = ROOT / "apps/mobile/test/data/required_preferred_cases.json"
MJC = source_config("mjc_www_notice")
PREF, ITEM = rules.PREFERRED_NOTE, rules.NO_LIMIT_NOTE

ENROLLED2 = {"university_id": "mjc", "major_id": None, "grade": 2, "enrollment_status": "enrolled"}
GRADUATED2 = {**ENROLLED2, "enrollment_status": "graduated"}
NO_GRADE = {**ENROLLED2, "grade": None}
ATTACHMENT = [{"file_name": "[합성] 모집요강.hwp", "url": None, "type": "hwp"}]


def run(body, profile=ENROLLED2, attachments=None):
    elig = RuleBasedAnalyzer().analyze(raw_notice(body, attachments=attachments), MJC)["eligibility"]
    status, results = evaluate(elig, profile)
    return elig, status, results


def parts(elig):
    """(필수 근거, 우대 근거, 항목 제한 없음 근거, 그 밖 근거)"""
    un = elig["unresolved_conditions"]
    return (
        [c["evidence"] for c in elig["conditions"]],
        [u["evidence"] for u in un if u["note"] == PREF],
        [u["evidence"] for u in un if u["note"] == ITEM],
        [u["evidence"] for u in un if u["note"] not in (PREF, ITEM)],
    )


def cond(elig, field):
    return next(c for c in elig["conditions"] if c["field"] == field)


# ---------- 7.1 팀장 결정 3건: id, 원문, 프로필, 첨부, 필수, 우대, 제한 없음, 그 밖, 판정 ----------

CASES = [
    ("A1", "학년 무관", ENROLLED2, None, [], [], ["학년 무관"], [], "needs_check"),
    ("A2", "학년 무관", NO_GRADE, None, [], [], ["학년 무관"], [], "needs_check"),
    ("A3", "학년 제한 없음\n관련 전공 우대", ENROLLED2, None, [], ["관련 전공 우대"], ["학년 제한 없음"], [], "needs_check"),
    ("A4", "재학생 대상, 학년 무관", ENROLLED2, None, ["재학생 대상, 학년 무관"], [], ["학년 무관"], [], "met"),
    ("A5", "누구나 지원 가능\n관련 전공 우대", ENROLLED2, None, [], ["관련 전공 우대"], [], [], "met"),
    ("B1", "지원 대상: 재학생(3~4학년 우대)", ENROLLED2, None, ["재학생"], ["3~4학년 우대"], [], [], "met"),
    ("B2", "지원 대상: 재학생(3~4학년 우대)", GRADUATED2, None, ["재학생"], ["3~4학년 우대"], [], [], "not_met"),
    ("B3", "우대 사항: 재학생(3~4학년 우대)", ENROLLED2, None, [], ["재학생(3~4학년 우대)"], [], [], "needs_check"),
    ("B4", "지원 자격: 3~4학년\n우대 사항: 재학생(3~4학년 우대)", ENROLLED2, None,
     ["지원 자격: 3~4학년"], ["재학생(3~4학년 우대)"], [], [], "not_met"),
    ("B5", "재학생(3~4학년 우대)", ENROLLED2, None, [], [], [], ["재학생(3~4학년 우대)"], "needs_check"),
    ("C1", "지원 자격 및 우대 사항\n지원 대상: 재학생\n우대: 3~4학년", ENROLLED2, None,
     ["지원 대상: 재학생"], ["3~4학년"], [], [], "met"),
    ("C2", "지원 자격 및 우대 사항\n지원 대상: 재학생\n우대: 3~4학년", GRADUATED2, None,
     ["지원 대상: 재학생"], ["3~4학년"], [], [], "not_met"),
    ("C3", "지원 자격 및 우대 사항\n3~4학년", ENROLLED2, None, [], [], [], ["3~4학년"], "needs_check"),
    ("C4", "지원 자격 및 우대 사항\n3. 신청 방법\n이메일로 접수", ENROLLED2, None, [], [], [], [], "needs_check"),
    ("C5", "자격 요건\n- 재학생 대상", ENROLLED2, None, ["- 재학생 대상"], [], [], [], "met"),
    ("C6", "지원 자격\n- 재학생 대상", ENROLLED2, None, ["- 재학생 대상"], [], [], [], "met"),
    ("C7", "본교 재학생 대상\n2. 자격 요건\n3. 신청 방법", ENROLLED2, None,
     ["본교 재학생 대상", "본교 재학생 대상"], [], [], [], "needs_check"),
    ("C8", "본교 재학생 대상\n2. 지원 자격\n3. 신청 방법", ENROLLED2, None,
     ["본교 재학생 대상", "본교 재학생 대상"], [], [], [], "needs_check"),
]


# 7.6 구역·항목 회귀 사례: 실제 공고의 형태를 본뜬 가상 문구
R1 = "\n".join([
    "자격요건 / 국가보훈대상자(필수)", "우대사항 / VC·PE 등 금융 관리업무 경험자", "• 전문학사 졸업 또는 동등 수준 이상 학위 소지자",
    "• 남자의 경우 병역필 또는 면제자", "• 최종합격일 이후 근무 가능한 자", "5 근무조건", "채용구분 / 계약직(1년)",
    "급여 / 연 3,600만원 수준", "근무시간 / 09:00~18:00",
])
R2 = "\n".join([
    "지원자격 / 모집 전공: 부동산·경영·회계 관련 학과", "우대사항 / 관련 자격증 보유자 우대, 외국어 능통자 우대", "- 영어 OPIc IH 이상 보유",
    "참고사항 / 근무지역", "- 수도권(서울/경기)", "채용절차 / 지원서 접수", "2026년 12월 중", "서류평가 / 직무적성검사",
])
R3 = "\n".join([
    "자격요건 및 우대사항", "[자격요건]", "- 관련 학사 이상 학위 보유자", "- 기계·전기·전자 전공", "- MS Office 기본 활용 가능자", "[우대사항]",
    "- 반도체 제조 공정 실무 경험자", "- 전기 관련 산업기사 자격증 보유자", "모집인원: 0명", "근무지: 인천", "담당 업무: 설비 유지보수",
    "회사소개 / 반도체 후공정 전문 기업입니다",
])
R5A = "우대사항 / 운전면허 소지자\n해당 지역 거주자에 한함"
R6 = "지원 자격: 재학생\n■ 우대사항\n- 운전면허 소지자\n- 문서 정리를 꼼꼼히 하시는 분\n근무지: 서울"


def golden_entry(case_id, body, profile, attachments):
    elig, status, results = run(body, profile, attachments)
    return {"id": case_id, "body": body, "eligibility": elig, "status": status, "results": results}


@pytest.mark.parametrize("case", CASES, ids=[c[0] for c in CASES])
def test_leader_decision_cases(case):
    case_id, body, profile, attachments, required, preferred, item, other, status = case
    elig, got, results = run(body, profile, attachments)
    assert parts(elig) == (required, preferred, item, other), case_id
    assert got == status, case_id
    # 우대·항목 제한 없음은 판정 결과에 들어가지 않는다
    assert all(r["evidence"] not in preferred + item for r in results)
    if case_id in ("A1", "A2", "A3", "B3", "B5", "C3", "C4"):
        assert results == [] and elig["explicitly_unrestricted"] is False and elig["extraction_complete"] is False
    if case_id in ("A4", "A5", "B1", "C1", "C5", "C6"):
        assert elig["extraction_complete"] is True
    if case_id in ("C7", "C8"):
        assert elig["extraction_complete"] is False  # 제목 아래에서 읽은 항목이 없음
        assert {r["field"]: r["status"] for r in results} == {"enrollment_status": "met", "university_id": "met"}


def test_a5_explicit_unrestricted_evidence():
    elig, status, _ = run("누구나 지원 가능\n관련 전공 우대")
    assert elig["explicitly_unrestricted"] is True and elig["unrestricted_evidence"] == "누구나 지원 가능"
    assert status == "met"


def test_split_evidence_vs_whole_line():
    elig, *_ = run("지원 대상: 재학생(3~4학년 우대)")
    assert cond(elig, "enrollment_status")["evidence"] == "재학생" and cond(elig, "enrollment_status")["value"] == "enrolled"
    assert all(c["field"] != "grade" for c in elig["conditions"])
    elig, *_ = run("재학생 대상, 학년 무관")
    assert cond(elig, "enrollment_status")["evidence"] == "재학생 대상, 학년 무관"


# ---------- 7.2 그 밖의 추출 -> 판정 ----------

def status_of(body, profile=ENROLLED2, attachments=None):
    return run(body, profile, attachments)[1]


def test_72_cases():
    # 1
    elig, st, _ = run("지원 자격: 재학생\n우대 사항: 3~4학년")
    assert parts(elig)[:2] == (["지원 자격: 재학생"], ["3~4학년"]) and st == "met"
    # 2, 3
    for body in ("재학생 대상, 3~4학년 우대", "3~4학년 우대, 재학생 대상"):
        elig, st, _ = run(body)
        assert parts(elig)[:2] == (["재학생 대상"], ["3~4학년 우대"]) and st == "met"
    # 4
    elig, *_ = run("3~4학년 재학생 우대")
    assert elig["conditions"] == [] and parts(elig)[1] == ["3~4학년 재학생 우대"]
    assert status_of("3~4학년 재학생 우대") == "needs_check" and status_of("3~4학년 재학생 우대", GRADUATED2) == "needs_check"
    # 5
    elig, st, _ = run("1·2학년 대상")
    assert (cond(elig, "grade")["value"], cond(elig, "grade")["evidence"]) == ([1, 2], "1·2학년 대상") and st == "met"
    assert status_of("1·2학년 대상", {**ENROLLED2, "grade": 3}) == "not_met"
    # 6: 괄호는 지금처럼 문장의 일부
    elig, *_ = run("재학생(휴학생 포함)")
    assert cond(elig, "enrollment_status")["value"] == ["enrolled", "on_leave"]
    assert cond(elig, "enrollment_status")["evidence"] == "재학생(휴학생 포함)"
    # 7
    body = "우대 사항\n3~4학년\n지원 자격\n재학생"
    assert status_of(body) == "met" and status_of(body, GRADUATED2) == "not_met"
    # 8
    assert status_of("지원 자격: 3~4학년만") == "not_met"
    assert status_of("지원 자격: 3~4학년만", NO_GRADE) == "needs_check"
    # 9, 10
    assert status_of("지원 자격: 재학생\n■ 우대사항\n- 3~4학년") == "met"
    assert status_of("지원 자격: 재학생\n우대사항: 없음") == "met"
    # 11
    elig, st, _ = run("3~4학년 우대")
    assert elig["conditions"] == [] and st == "needs_check" and parts(elig)[1] == ["3~4학년 우대"]
    # 12: 학과 사전에 있는 학과
    elig, st, _ = run("누구나 지원 가능, 컴퓨터공학과 학생 우대")
    assert all(c["field"] != "major_id" for c in elig["conditions"]) and st == "met"
    assert parts(elig)[1] == ["컴퓨터공학과 학생 우대"] and elig["unrestricted_evidence"] == "누구나 지원 가능"
    # 13
    elig, st, _ = run("지원 자격\n학점 3.0 이상\n우대 사항\n학점 3.0 이상")
    assert [(u["evidence"], u["note"]) for u in elig["unresolved_conditions"]] == [("학점 3.0 이상", None), ("학점 3.0 이상", PREF)]
    assert st == "needs_check"
    # 14
    elig, st, _ = run("지원 자격\n학점 3.0 이상\n우대 사항\n학점 3.0 이상 및 관련 자격증 소지자")
    assert [(u["evidence"], u["note"]) for u in elig["unresolved_conditions"]] == [
        ("학점 3.0 이상", None), ("학점 3.0 이상 및 관련 자격증 소지자", PREF)]
    assert st == "needs_check"
    # 15
    elig, st, results = run("지원 자격: 재학생\n우대 사항: 3~4학년", attachments=ATTACHMENT)
    assert st == "needs_check" and elig["extraction_complete"] is False
    assert [(r["field"], r["status"]) for r in results] == [("enrollment_status", "met")]
    # 16
    elig, st, _ = run("지원 자격: 재학생\n평점 3.0 이상", attachments=ATTACHMENT)
    assert st == "needs_check" and parts(elig)[3] == ["평점 3.0 이상"]
    # 17
    elig, st, results = run("학년 무관\n평점 3.0 이상")
    assert st == "needs_check" and parts(elig)[2:] == (["학년 무관"], ["평점 3.0 이상"]) and results == []


def test_marker_list_is_fixed():
    """역할 표지 목록 (명세 3.2: 구현 시 테스트로 고정)."""
    for text in ("3~4학년 우대", "3~4학년 우대함", "3~4학년 우대합니다."):
        assert rules._closing(text) == "preferred"
    for text in ("재학생 대상", "3학년만", "재학생에 한함", "3학년 한정", "토익 필수", "누구나 지원 가능", "누구나 참여 가능", "재학생 대상자"):
        assert rules._closing(text) == "required", text
    for text in ("재학생", "1·2학년", "3", "우대가점 포함"):
        assert rules._closing(text) is None, text


def test_preferred_label_names():
    for head in ("우대 사항", "우대사항", "우대조건", "우대 조건", "우대"):
        assert rules._heading_kind(head) == "preferred", head
    assert rules._heading_kind("지원자격 및 우대사항") == "mixed"
    assert rules._heading_kind("자격 요건") == "required"
    elig, st, _ = run("지원 자격: 재학생\n우대조건 : 워드, 엑셀 가능 자")
    assert parts(elig)[:2] == (["지원 자격: 재학생"], ["워드, 엑셀 가능 자"]) and st == "met"


def test_unmarked_midline_preferred_is_ambiguous_whole_line():
    elig, *_ = run("우대 조건은 별도 안내")
    assert parts(elig) == ([], [], [], ["우대 조건은 별도 안내"])


# ---------- 7.3 LLM 보강 (응답 고정) ----------

@pytest.fixture
def ollama():
    fake = FakeOllama()
    yield fake
    fake.server.shutdown()


def llm_run(ollama, body, reply, profile=ENROLLED2, attachments=None):
    ollama.reply = {"summary": None, "deadline": None, "conditions": [], "unresolved": [], **reply}
    a = OllamaAnalyzer("test-model", host=ollama.url, timeout=5)
    elig = a.analyze(raw_notice(body, attachments=attachments), MJC)["eligibility"]
    return elig, evaluate(elig, profile)[0], a


def c(field, value, evidence, op="in"):
    return {"field": field, "operator": op, "value": value, "evidence": evidence}


def test_l1_grade_cut_from_preferred_phrase(ollama):
    elig, st, a = llm_run(ollama, "지원 자격: 재학생\n3~4학년 우대", {"conditions": [c("grade", [3, 4], "3~4학년")]})
    assert all(x["field"] != "grade" for x in elig["conditions"]) and parts(elig)[1] == ["3~4학년 우대"]
    assert st == "met" and any("필수 구절 밖" in r for r in a.rejected)


def test_l2_major_in_preferred_phrase(ollama):
    reply = {"conditions": [c("major_id", "mjc.computer_engineering", "컴퓨터공학과 학생", "eq")]}
    elig, st, _ = llm_run(ollama, "누구나 지원 가능\n컴퓨터공학과 학생 우대", reply)
    assert elig["conditions"] == [] and elig["explicitly_unrestricted"] is True and st == "met"


def test_l3_enrollment_in_preferred_label(ollama):
    reply = {"conditions": [c("enrollment_status", "enrolled", "재학생", "eq")]}
    elig, st, _ = llm_run(ollama, "우대 사항: 재학생(3~4학년 우대)", reply)
    assert elig["conditions"] == [] and st == "needs_check" and parts(elig)[1] == ["재학생(3~4학년 우대)"]


def test_l4_grade_all_from_no_limit_phrase(ollama):
    elig, st, a = llm_run(ollama, "학년 무관", {"conditions": [c("grade", [1, 2, 3, 4], "학년 무관")]})
    assert elig["conditions"] == [] and st == "needs_check" and parts(elig)[2] == ["학년 무관"]
    assert any("필수 구절 밖" in r for r in a.rejected)


def test_l4b_no_limit_phrase_even_with_valid_value(ollama):
    elig, *_ = llm_run(ollama, "학년 무관", {"conditions": [c("grade", [2, 3], "학년 무관")]})
    assert elig["conditions"] == []


def test_l5_required_and_preferred_both_kept(ollama):
    body = "지원 자격\n학점 3.0 이상\n우대 사항\n학점 3.0 이상"
    elig, st, _ = llm_run(ollama, body, {"unresolved": ["학점 3.0 이상"]})
    assert [(u["evidence"], u["note"]) for u in elig["unresolved_conditions"]] == [("학점 3.0 이상", None), ("학점 3.0 이상", PREF)]
    assert st == "needs_check"


def test_l5b_llm_item_is_required_when_text_also_in_required_position(ollama):
    """규칙은 키워드가 없어 필수 쪽을 못 냈어도, LLM의 같은 문구는 우대 쪽에 가려지지 않고 필수 항목으로 남는다."""
    body = "지원 자격\n운전면허 소지자\n우대 사항\n운전면허 소지자"
    elig, *_ = llm_run(ollama, body, {"unresolved": ["운전면허 소지자"]})
    assert [(u["evidence"], u["note"]) for u in elig["unresolved_conditions"]] == [
        ("운전면허 소지자", None), ("운전면허 소지자", PREF)]


def test_l6_preferred_added_keeps_completeness_and_unrestricted(ollama):
    elig, st, _ = llm_run(ollama, "누구나 지원 가능\n운전면허 소지자 우대", {"unresolved": ["운전면허 소지자 우대"]})
    assert elig["extraction_complete"] is True and elig["explicitly_unrestricted"] is True and st == "met"
    assert parts(elig)[1] == ["운전면허 소지자 우대"]


def test_l6b_preferred_section_item_is_marked_preferred(ollama):
    elig, st, _ = llm_run(ollama, "누구나 지원 가능\n우대 사항\n운전면허 소지자", {"unresolved": ["운전면허 소지자"]})
    assert [(u["evidence"], u["note"]) for u in elig["unresolved_conditions"]] == [("운전면허 소지자", PREF)]
    assert elig["extraction_complete"] is True and st == "met"


def test_l7_non_preferred_text_lowers_completeness(ollama):
    elig, st, _ = llm_run(ollama, "누구나 지원 가능\n관련 전공 우대\n평점 3.0 이상", {"unresolved": ["평점 3.0 이상"]})
    assert elig["extraction_complete"] is False and elig["explicitly_unrestricted"] is False and st == "needs_check"
    assert parts(elig)[3] == ["평점 3.0 이상"]
    # 규칙이 못 잡는 문구도 같다
    elig, st, _ = llm_run(ollama, "누구나 지원 가능\n관련 전공 우대\n운전면허 소지자", {"unresolved": ["운전면허 소지자"]})
    assert parts(elig)[3] == ["운전면허 소지자"] and elig["explicitly_unrestricted"] is False and st == "needs_check"


def test_l8_never_raises_completeness(ollama):
    reply = {"unresolved": ["3~4학년"]}
    elig, st, _ = llm_run(ollama, "지원 자격: 재학생\n우대 사항: 3~4학년", reply, attachments=ATTACHMENT)
    assert elig["extraction_complete"] is False and st == "needs_check"


def test_llm_valid_required_condition_still_accepted(ollama):
    reply = {"conditions": [c("major_id", "mjc.computer_engineering", "컴퓨터공학과에 재학 중인 학생", "eq")]}
    elig, *_ = llm_run(ollama, "지원 자격: 재학생\n컴퓨터공학과에 재학 중인 학생", reply)
    assert cond(elig, "major_id")["value"] == "mjc.computer_engineering"


# ---------- 7.4 소비자 ----------

def test_judge_ignores_flagged_items_and_incomplete_with_preferred_only():
    base = {"conditions": [], "unresolved_conditions": [{"evidence": "관련 전공 우대", "note": PREF}],
            "extraction_complete": False, "explicitly_unrestricted": False, "unrestricted_evidence": None}
    assert evaluate(base, ENROLLED2) == ("needs_check", [])
    full = {**base, "extraction_complete": True, "explicitly_unrestricted": True, "unrestricted_evidence": "누구나",
            "unresolved_conditions": [{"evidence": "학년 무관", "note": ITEM}, {"evidence": "관련 전공 우대", "note": PREF}]}
    assert evaluate(full, ENROLLED2) == ("met", [])
    real = {**full, "unresolved_conditions": full["unresolved_conditions"] + [{"evidence": "평점 3.0 이상", "note": None}]}
    assert evaluate(real, ENROLLED2)[0] == "needs_check"


def test_flag_values_match_in_three_places():
    assert (rules.PREFERRED_NOTE, rules.NO_LIMIT_NOTE) == (judge.PREFERRED_NOTE, judge.NO_LIMIT_NOTE)
    assert (rules.PREFERRED_NOTE, rules.NO_LIMIT_NOTE) == (agent_prompt.PREFERRED_NOTE, agent_prompt.NO_LIMIT_NOTE)


def _notice(items):
    return {"eligibility": {"unresolved_conditions": [{"evidence": e, "note": n} for e, n in items]}}


def test_prompt_excludes_no_limit_and_marks_only_preferred():
    items = [("학점 3.0 이상", None), ("학점 3.0 이상", PREF), ("학년 무관", ITEM)]
    report = {"skills": "학점 3.0 이상\n학점 3.0 이상 (우대)"}
    out, _ = agent_prompt.ground_report(report, _notice(items), "needs_check", date(2026, 11, 25))
    assert out["skills"].split(agent_prompt.BR) == ["학점 3.0 이상", "학점 3.0 이상 (우대)"]
    out, _ = agent_prompt.ground_report({"skills": "학년 무관"}, _notice(items), "needs_check", date(2026, 11, 25))
    assert out["skills"] == agent_prompt.SKILLS_UNKNOWN


def test_prompt_material_lists_no_limit_nowhere_as_condition():
    notice = {
        "title": "t", "category": "other", "summary": "s", "application_deadline": None,
        "eligibility": {"conditions": [], "extraction_complete": False, "explicitly_unrestricted": False,
                        "unresolved_conditions": [{"evidence": "학년 무관", "note": ITEM}, {"evidence": "관련 전공 우대", "note": PREF}]},
    }
    _, user = agent_prompt.build_messages(notice, {}, ("needs_check", []), date(2026, 11, 25))
    material = json.loads(user)
    listed = material["공고"]["지원 자격 판정"]["원문에서 확인할 조건"]
    assert listed == [{"원문": "관련 전공 우대", "구분": PREF}]


def test_external_eligibility_has_no_flags():
    """외부 공고 경로는 우대·항목 제한 없음 표시를 만들지 않아 판정이 바뀌지 않는다."""
    src = (ROOT / "backend/agent/external.py").read_text(encoding="utf-8")
    assert "우대 사항" not in src and "항목 제한 없음" not in src


def test_golden_matches_backend():
    entries = [golden_entry(cid, body, profile, att) for cid, body, profile, att, *_ in CASES]
    entries += [
        golden_entry("S13", "지원 자격\n학점 3.0 이상\n우대 사항\n학점 3.0 이상", ENROLLED2, None),
        golden_entry("S15", "지원 자격: 재학생\n우대 사항: 3~4학년", ENROLLED2, ATTACHMENT),
        golden_entry("S16", "지원 자격: 재학생\n평점 3.0 이상", ENROLLED2, ATTACHMENT),
        golden_entry("S17", "학년 무관\n평점 3.0 이상", ENROLLED2, None),
        golden_entry("R1", R1, ENROLLED2, None),
        golden_entry("R3", R3, ENROLLED2, None),
        golden_entry("R5A", R5A, ENROLLED2, None),
    ]
    if os.environ.get("UPDATE_GOLDEN"):
        GOLDEN.parent.mkdir(parents=True, exist_ok=True)
        GOLDEN.write_text(json.dumps(entries, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    assert json.loads(GOLDEN.read_text(encoding="utf-8")) == entries
