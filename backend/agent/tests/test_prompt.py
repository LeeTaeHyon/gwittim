import json
import re
from datetime import date

from backend.agent.prompt import SYSTEM_PROMPT, build_messages, scrub_codes

NOTICE = {
    "title": "[일반채용] 합성 AI 인턴십",
    "category": "internship",
    "summary": "합성 요약입니다.",
    "application_deadline": None,
    "activity_period": {
        "start": {"date": "2027-03-02", "time": None, "timezone": None, "precision": "date", "evidence": "3월부터"},
        "end": None, "evidence": "3월부터 5개월",
    },
    "eligibility": {
        "conditions": [{"field": "enrollment_status", "operator": "eq", "value": "graduated",
                        "evidence": "졸업 예정자 또는 기졸업자", "validation_status": "validated"}],
        "unresolved_conditions": [{"evidence": "AI 결과물 경험", "note": "우대 사항"}, {"evidence": "병역필", "note": None}],
        "extraction_complete": True,
        "explicitly_unrestricted": False,
    },
}
PAYLOAD = {
    "university_id": "mjc", "major_id": "mjc.computer_engineering", "grade": 2, "enrollment_status": "enrolled",
    "interest_ids": ["ai_data"], "target_role_ids": ["software_developer"],
    "experience": ["python", "team_project"], "period": "vacation", "regions": ["seoul"],
}
VERDICT = ("not_met", [{"field": "enrollment_status", "status": "not_met",
                        "evidence": "졸업 예정자 또는 기졸업자", "unknown_reason": None}])
CODE_RE = re.compile(r"\b(not_met|needs_check|met|null|true|false|enrollment_status|university_id|major_id|"
                     r"graduated|enrolled|on_leave|team_project|software_developer|ai_data|vacation|seoul|python)\b")


def material():
    _, user = build_messages(NOTICE, PAYLOAD, VERDICT, date(2026, 11, 22))
    return user, json.loads(user)


def test_material_has_no_internal_codes():
    user, _ = material()
    assert not CODE_RE.findall(user)
    assert not re.search(r'"[a-z_]+":', user)  # 칸 이름도 한국어


def test_material_korean_values():
    _, m = material()
    s = m["학생"]
    assert s["학적 상태"] == "재학" and s["학년"] == "2학년" and s["학과"] == "컴퓨터공학과"
    assert s["해 본 것"] == ["파이썬", "팀 프로젝트"] and s["가능한 시기"] == "방학" and s["갈 수 있는 지역"] == ["서울"]
    n = m["공고"]
    assert n["마감"] == "미상"
    assert n["활동 기간"] == "2027-03-02 ~ 미상"
    v = n["지원 자격 판정"]
    assert v["결과"] == "불충족"
    assert v["조건별 결과"] == [{"항목": "학적 상태", "결과": "불충족", "근거": "졸업 예정자 또는 기졸업자",
                             "공고 조건": "졸업·졸업 예정"}]
    assert v["자동 비교하지 못한 조건"][1] == {"원문": "병역필", "구분": "자격 조건"}


def test_missing_profile_fields_are_left_out():
    _, user = build_messages(NOTICE, {}, ("needs_check", []), date(2026, 11, 22))
    assert json.loads(user)["학생"] == {}


def test_minute_deadline_keeps_time_without_timezone():
    notice = {**NOTICE, "application_deadline": {"date": "2026-11-30", "time": "18:00", "timezone": None,
                                                 "precision": "minute", "evidence": "18시"}}
    _, user = build_messages(notice, PAYLOAD, VERDICT, date(2026, 11, 22))
    assert json.loads(user)["공고"]["마감"] == "2026-11-30 18:00"


def test_system_prompt_rules():
    assert "영어 코드" in SYSTEM_PROMPT and "가능한 시기" in SYSTEM_PROMPT and "json" in SYSTEM_PROMPT
    assert "null" not in SYSTEM_PROMPT.split("영어 코드")[0]  # 규칙 앞에서 코드를 쓰지 않는다


def test_scrub_replaces_leaked_codes():
    report = {
        "fit": "파이썬(team_project) 경험이 연결됨.",
        "eligibility": "판정은 not_met(불충족)입니다. enrollment_status 조건이 not_met입니다.",
        "todo": "마감은 입력상 null로 마감 미상입니다. `needs_check` 항목 확인.",
        "skills": "공고 원문 확인 필요.",
    }
    out, n = scrub_codes(report)
    assert out["eligibility"] == "판정은 불충족입니다. 학적 상태 조건이 불충족입니다."
    assert out["todo"] == "마감은 입력상 미상로 마감 미상입니다. 확인 필요 항목 확인."
    assert out["fit"] == "파이썬 경험이 연결됨."
    assert out["skills"] == report["skills"]
    assert n == 6


def test_scrub_leaves_urls_and_ordinary_english():
    text = "https://www.mjc.ac.kr/x?menu=met 에서 Python, AI, any 경험 확인. met-life 아님. Metro 근무."
    out, n = scrub_codes({"fit": text})
    assert out["fit"] == text and n == 0
