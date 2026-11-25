"""구역·항목 줄 회귀 사례 R1~R6 (docs/eligibility-required-preferred-spec.md §7.6).

실제 공고 세 건(표가 펼쳐진 공고, 직무별 반복 공고, 혼합 제목 아래 하위 제목)의 형태를 본뜬 가상 문구다.
항목 목록 전체(근거 문구, note)를 정확히 비교한다. 규칙만 쓴 경우와 LLM 응답을 고정한 경우를 모두 확인한다.
"""
import pytest

from backend.analysis.tests.test_required_preferred import (  # noqa: F401  (ollama는 픽스처)
    ENROLLED2,
    ITEM,
    PREF,
    R1,
    R2,
    R3,
    R5A,
    R6,
    llm_run,
    ollama,
    run,
)

R5B = "근무지: 서울 강남\n서울시 거주자에 한함"
R4A = "지원 자격: 학력 및 전공 무관 (특정 모집 부문 제외)"
R4B = "학년 무관, 기존 수상작 응모 제외"

# 사례: (id, 원문, 기대 항목[(근거, note)], 기대 필수 조건 수, 판정, LLM이 내는 미해석 문구(안내 줄·중복 포함))
CASES = [
    ("R1", R1, [
        ("국가보훈대상자(필수)", None),
        ("VC·PE 등 금융 관리업무 경험자", PREF),
        ("전문학사 졸업 또는 동등 수준 이상 학위 소지자", None),
        ("남자의 경우 병역필 또는 면제자", None),
        ("최종합격일 이후 근무 가능한 자", None),
    ], 0, "needs_check", [
        "국가보훈대상자(필수)", "VC·PE 등 금융 관리업무 경험자", "전문학사 졸업 또는 동등 수준 이상 학위 소지자",
        "남자의 경우 병역필 또는 면제자", "최종합격일 이후 근무 가능한 자", "연 3,600만원 수준", "09:00~18:00", "계약직(1년)",
    ]),
    ("R2", R2, [
        ("모집 전공: 부동산·경영·회계 관련 학과", None),
        ("관련 자격증 보유자 우대", PREF),
        ("외국어 능통자 우대", PREF),
        ("영어 OPIc IH 이상 보유", None),
    ], 0, "needs_check", [
        "모집 전공: 부동산·경영·회계 관련 학과", "관련 자격증 보유자 우대", "외국어 능통자 우대", "영어 OPIc IH 이상 보유",
        "수도권(서울/경기)", "지원서 접수", "직무적성검사",
    ]),
    ("R3", R3, [
        ("관련 학사 이상 학위 보유자", None),
        ("기계·전기·전자 전공", None),
        ("MS Office 기본 활용 가능자", None),
        ("반도체 제조 공정 실무 경험자", PREF),
        ("전기 관련 산업기사 자격증 보유자", PREF),
    ], 0, "needs_check", [
        "관련 학사 이상 학위 보유자", "기계·전기·전자 전공", "MS Office 기본 활용 가능자", "반도체 제조 공정 실무 경험자",
        "전기 관련 산업기사 자격증 보유자", "모집인원: 0명", "근무지: 인천", "설비 유지보수", "반도체 후공정 전문 기업입니다",
    ]),
    ("R4a", R4A, [("학력 및 전공 무관 (특정 모집 부문 제외)", None)], 0, "needs_check", ["학력 및 전공 무관"]),
    ("R4b", R4B, [("학년 무관", ITEM), ("기존 수상작 응모 제외", None)], 0, "needs_check", ["기존 수상작 응모 제외"]),
    ("R5a", R5A, [("운전면허 소지자", PREF), ("해당 지역 거주자에 한함", None)], 0, "needs_check",
     ["운전면허 소지자", "해당 지역 거주자에 한함"]),
    ("R5b", R5B, [("서울시 거주자에 한함", None)], 0, "needs_check", ["서울시 거주자에 한함", "서울 강남"]),
    ("R6", R6, [("운전면허 소지자", PREF), ("문서 정리를 꼼꼼히 하시는 분", PREF)], 1, "met",
     ["운전면허 소지자", "문서 정리를 꼼꼼히 하시는 분", "서울"]),
]
IDS = [c[0] for c in CASES]


def items(elig):
    return [(u["evidence"], u["note"]) for u in elig["unresolved_conditions"]]


@pytest.mark.parametrize("case", CASES, ids=IDS)
def test_rules_only_items_match_exactly(case):
    _, body, expected, n_conditions, status, _ = case
    elig, got, results = run(body, ENROLLED2)
    assert items(elig) == expected
    assert len(elig["conditions"]) == n_conditions and got == status
    # 직접 확인 항목 수가 서버 판정 확인 개수의 근거다: 우대·항목 제한 없음은 세지 않는다
    assert all(r["evidence"] not in [e for e, n in expected if n in (PREF, ITEM)] for r in results)


@pytest.mark.parametrize("case", CASES, ids=IDS)
def test_llm_fixed_response_keeps_same_items(ollama, case):
    """LLM이 안내 줄·중복 문구를 보내도 항목 목록이 규칙만 쓴 경우와 같다: 우대로 옮기지도, 안내 줄을 항목으로 만들지도 않는다."""
    _, body, expected, n_conditions, status, llm_texts = case
    elig, got, _ = llm_run(ollama, body, {"unresolved": llm_texts})
    assert items(elig) == expected
    assert len(elig["conditions"]) == n_conditions and got == status


def test_r1_common_requirements_are_not_preferred():
    elig, *_ = run(R1)
    prefs = [e for e, n in items(elig) if n == PREF]
    assert prefs == ["VC·PE 등 금융 관리업무 경험자"]


def test_r2_preferred_label_does_not_pass_role_to_next_line():
    elig, *_ = run(R2)
    assert ("영어 OPIc IH 이상 보유", None) in items(elig)


def test_r6_table_item_closes_preferred_section():
    elig, st, _ = run(R6)
    assert all("서울" not in e for e, _n in items(elig)) and st == "met"


def test_exception_phrase_does_not_touch_other_phrases():
    elig, *_ = run("학년 무관, 기존 수상작 응모 제외")
    assert ("학년 무관", ITEM) in items(elig)
    assert all(e != "학년 무관, 기존 수상작 응모 제외" for e, _ in items(elig))


def test_bracket_titles_open_sections_and_close_previous():
    from backend.analysis import rules

    kinds = [(i.kind, i.heading) for i in rules.read_lines(rules.clean_lines(R3.splitlines())) if i.kind == "heading"]
    assert kinds == [("heading", "mixed"), ("heading", "required"), ("heading", "preferred")]


def test_dotless_number_and_hash_titles_close_section():
    from backend.analysis import rules

    infos = rules.read_lines(["■ 우대사항", "- 운전면허 소지자", "5 근무조건", "- 독서 모임 참여자"])
    assert infos[1].sect == "preferred" and infos[3].sect is None
    infos = rules.read_lines(["■ 우대사항", "- 운전면허 소지자", "## 모집 개요", "- 독서 모임 참여자"])
    assert infos[3].sect is None
