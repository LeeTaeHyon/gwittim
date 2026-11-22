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
    assert v["결과"] == "미충족"
    assert v["조건별 결과"] == [{"항목": "학적 상태", "결과": "미충족", "근거": "졸업 예정자 또는 기졸업자",
                             "공고 조건": "졸업·졸업 예정"}]
    assert v["원문에서 확인할 조건"][1] == {"원문": "병역필", "구분": "자격 조건"}
    assert v["참고"] == []  # 조건을 다 찾았고 '누구나' 문구도 없음


def test_notes_are_sentences_not_yes_no():
    el = {**NOTICE["eligibility"], "extraction_complete": False, "explicitly_unrestricted": True}
    _, user = build_messages({**NOTICE, "eligibility": el}, PAYLOAD, VERDICT, date(2026, 11, 22))
    v = json.loads(user)["공고"]["지원 자격 판정"]
    assert v["참고"] == ["공고의 지원 조건을 모두 찾지 못했을 수 있어 원문 확인이 필요함", "공고에 누구나 지원할 수 있다고 적혀 있음"]
    assert "아니요" not in user and '"예"' not in user


def test_missing_profile_fields_are_left_out():
    _, user = build_messages(NOTICE, {}, ("needs_check", []), date(2026, 11, 22))
    assert json.loads(user)["학생"] == {}


def test_activity_period_left_out_when_not_extracted():
    _, user = build_messages({**NOTICE, "activity_period": None}, PAYLOAD, VERDICT, date(2026, 11, 22))
    assert "활동 기간" not in json.loads(user)["공고"]


def test_minute_deadline_keeps_time_without_timezone():
    notice = {**NOTICE, "application_deadline": {"date": "2026-11-30", "time": "18:00", "timezone": None,
                                                 "precision": "minute", "evidence": "18시"}}
    _, user = build_messages(notice, PAYLOAD, VERDICT, date(2026, 11, 22))
    assert json.loads(user)["공고"]["마감"] == "2026-11-30 18:00"


def test_system_prompt_rules():
    assert "영어 코드" in SYSTEM_PROMPT and "가능한 시기" in SYSTEM_PROMPT and "json" in SYSTEM_PROMPT
    assert "칸 이름" in SYSTEM_PROMPT and "연결 근거가 드러나게" in SYSTEM_PROMPT
    assert "null" not in SYSTEM_PROMPT.split("영어 코드")[0]  # 규칙 앞에서 코드를 쓰지 않는다


def test_scrub_replaces_leaked_codes():
    report = {
        "fit": "파이썬(team_project) 경험이 연결됨.",
        "eligibility": "판정은 not_met(미충족)입니다. enrollment_status 조건이 not_met입니다.",
        "todo": "마감은 입력상 null로 마감 미상입니다. `needs_check` 항목 확인.",
        "skills": "공고 원문 확인 필요.",
    }
    out, n = scrub_codes(report)
    assert out["eligibility"] == "판정은 미충족입니다. 학적 상태 조건이 미충족입니다."
    assert out["todo"] == "마감은 입력상 미상로 마감 미상입니다. 확인 필요 항목 확인."
    assert out["fit"] == "파이썬 경험이 연결됨."
    assert out["skills"] == report["skills"]
    assert n == 6


def test_scrub_leaves_urls_and_ordinary_english():
    text = "https://www.mjc.ac.kr/x?menu=met 에서 Python, AI, any 경험 확인. met-life 아님. Metro 근무."
    out, n = scrub_codes({"fit": text})
    assert out["fit"] == text and n == 0


# ---------- 읽기 쉬운 줄 나누기 ----------

from backend.agent.prompt import split_long_lines  # noqa: E402


def test_prompt_asks_short_lines_and_labels():
    assert "줄바꿈(" + chr(92) + "n)" in SYSTEM_PROMPT and "맞음:" in SYSTEM_PROMPT and "미충족:" in SYSTEM_PROMPT
    assert "공고 자료에 적힌 역량만" in SYSTEM_PROMPT


def test_split_long_paragraph_at_sentence_ends():
    long = ("공고의 구매 업무는 식자재 계약관리와 구매 운영입니다. 학생이 해 본 데이터 분석은 관련이 적지 않습니다. "
            "근무지가 서울인지는 공고 자료로 확인되지 않아 원문 확인이 필요합니다.")
    out, n = split_long_lines({"fit": long, "skills": "식자재 계약관리\nERP 시스템 (우대)"})
    assert out["fit"].split("\n") == [
        "공고의 구매 업무는 식자재 계약관리와 구매 운영입니다.",
        "학생이 해 본 데이터 분석은 관련이 적지 않습니다.",
        "근무지가 서울인지는 공고 자료로 확인되지 않아 원문 확인이 필요합니다.",
    ]
    assert n == 2
    assert out["skills"] == "식자재 계약관리\nERP 시스템 (우대)"  # 짧은 줄은 그대로


def test_split_keeps_short_lines_and_numbers():
    text = "맞음: 관심 분야와 겹침\n확인 필요: 마감 2026. 11. 30. 이후 일정은 원문 확인"
    out, n = split_long_lines({"fit": text})
    assert out["fit"] == text and n == 0


def test_prompt_first_card_rules():
    """첫 칸(나와 이 공고)·지원 자격·할 일·역량 규칙 (2026-11-23 리포트 개선)."""
    s = SYSTEM_PROMPT
    assert "나와 이 공고" in s and "가장 큰 영향" in s
    assert "거주지가 아닙니다" in s and "단정하지 않고" in s  # 활동 지역은 거주지가 아님
    assert "숙련도나 맡은 역할을 추정하지 않습니다" in s  # 경험 칩만으로 숙련도 추정 금지
    assert "판정을 가른 조건" in s and "학생 정보가 비어서인지" in s and "공고 조건이 불명확해서인지" in s
    assert "필수 자격이 아니라" in s  # 우대 사항 구분
    assert "지원서 작성을 권하지 않습니다" in s  # 미충족이면
    assert "입력 자료에 없는 일정이나 경로를 만들어 쓰지 않습니다" in s  # '다음 학기·학과 공지' 같은 근거 없는 안내 금지
    assert '"fit"에서 같은 조건을 다시 말하지 않습니다' in s  # 판정 조건은 eligibility에서만
    assert "최대 4줄" in s and "제공된 공고 정보에서 요구 역량을 확인하기 어렵습니다" in s
    assert "번호, 글머리 기호" in s  # 앱이 붙임
    assert "불충족" not in s  # ui-style: 충족 / 미충족 / 확인 필요

