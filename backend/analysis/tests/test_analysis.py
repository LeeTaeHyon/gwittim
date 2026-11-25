import json
from datetime import date
from pathlib import Path

import pytest

from backend.analysis import RuleBasedAnalyzer, build_notice, validate
from backend.collectors.common import InMemoryStore, content_hash, ingest
from backend.contracts import schema_errors
from backend.recommendation import evaluate, recommend
from backend.sources import source_config

ROOT = Path(__file__).resolve().parents[3]
TODAY = date(2026, 10, 17)
MJC = source_config("mjc_www_notice")
PROFILE = json.loads((ROOT / "fixtures/valid/user_profile/complete.json").read_text(encoding="utf-8"))


def raw_notice(body: str, title="[합성 샘플] 2026학년도 아이디어 경진대회 참가 안내", attachments=None, **extra) -> dict:
    raw = json.loads((ROOT / "fixtures/valid/raw_notice/mjc_board_date_only.json").read_text(encoding="utf-8"))
    raw.update(title=title, body_text=body, attachments=attachments if attachments is not None else [], **extra)
    raw["content_hash"] = content_hash(raw)
    return raw


def record_for(raw: dict, store=None):
    store = store or InMemoryStore()
    result = ingest(raw, store)
    return store.records[result.key], store


CONTEST = (
    "운영대상: 우리대학 2~3학년 재학생\n"
    "신청기간: 2026.10.20.(화) ~ 2026.11.02.(월)\n"
    "본선 일시: 2026.11.13.(금) 15:00 ~ 17:00, 본관 510호\n"
)


def test_contest_notice_fields():
    fields = RuleBasedAnalyzer().analyze(raw_notice(CONTEST), MJC)
    assert fields["category"] == "contest"
    assert fields["application_start"]["date"] == "2026-10-20"
    deadline = fields["application_deadline"]
    assert (deadline["date"], deadline["time"], deadline["timezone"], deadline["precision"]) == ("2026-11-02", None, None, "date")
    conds = {c["field"]: c for c in fields["eligibility"]["conditions"]}
    assert conds["grade"]["value"] == [2, 3]
    assert conds["enrollment_status"]["value"] == "enrolled"
    assert conds["university_id"]["value"] == "mjc"
    assert fields["eligibility"]["extraction_complete"] is True


def test_deadline_with_time_gets_source_timezone():
    fields = RuleBasedAnalyzer().analyze(raw_notice("접수 마감: 2026. 10.18.(일) 10:00 까지"), MJC)
    d = fields["application_deadline"]
    assert (d["date"], d["time"], d["timezone"], d["precision"]) == ("2026-10-18", "10:00", "Asia/Seoul", "minute")


def test_work_period_is_activity_not_deadline():
    body = "1) 근로기간 : 2026. 9. 1.(화) ~ 12.14.(월)까지\n신청기간: 2026.08.11.(화) ~ 2026.08.20.(목)"
    fields = RuleBasedAnalyzer().analyze(raw_notice(body), MJC)
    assert fields["application_deadline"]["date"] == "2026-08-20"
    assert fields["activity_period"]["end"]["date"] == "2026-12-14"
    only_period = RuleBasedAnalyzer().analyze(raw_notice("1) 근로기간 : 2026. 9. 1.(화) ~ 12.14.(월)까지"), MJC)
    assert only_period["application_deadline"] is None
    # 신청·접수를 함께 말하면 마감으로 본다
    both = RuleBasedAnalyzer().analyze(raw_notice("교육기간 중 신청 접수: 2026.11.02.(월)까지"), MJC)
    assert both["application_deadline"]["date"] == "2026-11-02"


def test_first_come_is_note_not_deadline():
    fields = RuleBasedAnalyzer().analyze(raw_notice("해외 연수 참가자 모집\n선착순 마감 (정원 도달 시 조기 종료)"), MJC)
    assert fields["application_deadline"] is None
    assert fields["deadline_note"] == "선착순 마감 (정원 도달 시 조기 종료)"


def test_attachment_or_unresolved_keeps_extraction_incomplete():
    attach = [{"file_name": "모집요강.hwp", "url": None, "type": "hwp"}]
    fields = RuleBasedAnalyzer().analyze(raw_notice(CONTEST, attachments=attach), MJC)
    assert fields["eligibility"]["extraction_complete"] is False
    fields = RuleBasedAnalyzer().analyze(raw_notice(CONTEST + "직전 학기 평점 3.0 이상\n"), MJC)
    elig = fields["eligibility"]
    assert elig["extraction_complete"] is False
    assert elig["unresolved_conditions"] == [{"evidence": "직전 학기 평점 3.0 이상", "note": None}]


def test_image_read_through_alt_text_does_not_block_completeness():
    def complete(images: int, read: int) -> bool:
        raw = raw_notice(CONTEST)
        raw["source_fields"] = dict(raw["source_fields"], body_image_count=images)
        if read:
            raw["source_fields"]["body_image_text_count"] = read
        return RuleBasedAnalyzer().analyze(raw, MJC)["eligibility"]["extraction_complete"]

    assert complete(1, 0) is False  # 읽지 못한 포스터
    assert complete(1, 1) is True  # 대체텍스트로 읽은 포스터 (D-014)
    assert complete(2, 1) is False


def test_non_eligibility_no_limit_is_not_unrestricted():
    elig = RuleBasedAnalyzer().analyze(raw_notice("제출서류: 인턴 자기소개서 (분량 제한 없음)"), MJC)["eligibility"]
    assert elig["explicitly_unrestricted"] is False


def test_residence_and_nationality_are_unresolved():
    body = "대상: 우리대학 재학생\n충남 지역에 주민등록을 둔 학생\n대한민국 국적의 국내 대학 재학생"
    elig = RuleBasedAnalyzer().analyze(raw_notice(body), MJC)["eligibility"]
    assert len(elig["unresolved_conditions"]) == 2 and elig["extraction_complete"] is False


def test_mixed_enrollment_statuses_are_unresolved():
    line = "신청대상은 재학생, 신입생 2학기 입학예정자, 편입생, 재입학생, 복학생"
    elig = RuleBasedAnalyzer().analyze(raw_notice(line), MJC)["eligibility"]
    assert not any(c["field"] == "enrollment_status" for c in elig["conditions"])
    assert elig["unresolved_conditions"] == [{"evidence": line, "note": None}]


def test_no_conditions_found_is_not_unrestricted():
    elig = RuleBasedAnalyzer().analyze(raw_notice("많은 참여 바랍니다."), MJC)["eligibility"]
    assert (elig["conditions"], elig["explicitly_unrestricted"], elig["extraction_complete"]) == ([], False, False)


def test_explicitly_unrestricted():
    elig = RuleBasedAnalyzer().analyze(raw_notice("학년·학과 제한 없이 누구나 참여 가능"), MJC)["eligibility"]
    assert elig["explicitly_unrestricted"] is True
    assert elig["unrestricted_evidence"] == "학년·학과 제한 없이 누구나 참여 가능"


@pytest.mark.parametrize("body", [
    "학년 제한 없음\n소득분위 3분위 이하",
    "지원자격: 학년 제한 없음, 소득분위 3분위 이하",
    "학년 무관, 소득분위 3분위 이하",
])
def test_unrestricted_phrase_with_unresolved_condition_is_not_unrestricted(body):
    """제한 없음 문구가 있어도 소득 같은 미해석 조건이 남으면 제한 없음이 아니다 (SPEC §5·§6)."""
    elig = RuleBasedAnalyzer().analyze(raw_notice(body), MJC)["eligibility"]
    assert elig["explicitly_unrestricted"] is False and elig["unrestricted_evidence"] is None
    assert any("소득분위 3분위 이하" in u["evidence"] for u in elig["unresolved_conditions"])
    assert elig["extraction_complete"] is False
    assert evaluate(elig, PROFILE)[0] == "needs_check"


def test_unrestricted_with_attachment_is_needs_check():
    attachment = [{"file_name": "[합성] 모집요강.hwp", "url": None, "type": "hwp"}]
    elig = RuleBasedAnalyzer().analyze(raw_notice("학년·학과 제한 없이 누구나 참여 가능", attachments=attachment), MJC)["eligibility"]
    assert elig["explicitly_unrestricted"] is True and elig["extraction_complete"] is False
    assert evaluate(elig, PROFILE)[0] == "needs_check"


def test_major_condition_and_tags():
    fields = RuleBasedAnalyzer().analyze(raw_notice("컴퓨터공학과 재학생 대상 소프트웨어 개발자 특강"), MJC)
    conds = {c["field"]: c["value"] for c in fields["eligibility"]["conditions"]}
    assert conds["major_id"] == "mjc.computer_engineering"
    assert "mjc.computer_engineering" in fields["related_majors"]
    assert "software" in fields["interest_tags"] and "software_developer" in fields["related_roles"]


def test_department_names_are_not_tags():
    # 실제 공지: 담당 부서 '취·창업팀', 'AI·IR센터'가 창업·AI 공고로 잡히던 문제
    fields = RuleBasedAnalyzer().analyze(
        raw_notice("문의: 진로취·창업팀\n설문 주관: AI·IR센터", title="2026-2학기 취업 온라인 콘텐츠 수강 안내"), MJC
    )
    assert "startup" not in fields["interest_tags"] and "ai_data" not in fields["interest_tags"]
    assert "entrepreneur" not in fields["related_roles"]


def test_topic_keywords_give_roles_and_majors():
    fields = RuleBasedAnalyzer().analyze(raw_notice("일본어·중국어(HSK) 회화반 모집, 해커톤 참가팀 모집"), MJC)
    assert {"mjc.japanese", "mjc.chinese_business", "mjc.computer_engineering"} <= set(fields["related_majors"])
    assert "software_developer" in fields["related_roles"]


def test_lookalike_words_are_not_tags():
    fields = RuleBasedAnalyzer().analyze(
        raw_notice("창업보육센터 입주기업 모집\n대상: 외국인 유학생 포함\n항공편 개별 예약"), MJC
    )
    assert "education_welfare" not in fields["interest_tags"] and "global_language" not in fields["interest_tags"]
    assert not {"mjc.early_childhood_education", "mjc.aviation_service"} & set(fields["related_majors"])


def test_staff_notice_is_admin_without_tags():
    fields = RuleBasedAnalyzer().analyze(
        raw_notice("전임교원 소프트웨어 분야 공개채용, 원서접수기간: 2026.10.26.(월) ~ 2026.10.30.(금)", title="[교원초빙] 2027.03.01.자 전임교원 교수초빙"),
        MJC,
    )
    assert fields["category"] == "admin_notice"
    assert fields["interest_tags"] == [] and fields["related_roles"] == [] and fields["related_majors"] == []


def test_job_board_outside_staff_hiring_is_a_job():
    job = source_config("mjc_www_job")
    outside = raw_notice("", title="[일반채용] 한국수산자원공단 2026년도 제1차 직원 채용 공고", source_id="mjc_www_job")
    fields = RuleBasedAnalyzer().analyze(outside, job)
    assert fields["category"] == "job"
    assert "public_official" in fields["related_roles"] and "public_service" in fields["interest_tags"]
    lecturer = raw_notice("", title="[강사초빙] 2026. 9. 1.자 명지전문대학 강사 공개채용 공고", source_id="mjc_www_job")
    assert RuleBasedAnalyzer().analyze(lecturer, job)["category"] == "admin_notice"
    # 공지사항 게시판의 '직원 채용'은 지금처럼 학교 직원 채용으로 본다
    staff = raw_notice("", title="2026년 하반기 직원 채용 공고")
    assert RuleBasedAnalyzer().analyze(staff, MJC)["category"] == "admin_notice"


def test_job_keyword_lookalikes_are_not_tags():
    fields = RuleBasedAnalyzer().analyze(raw_notice("실습 기자재 지원 프로그램\n결과는 3영업일 이내 안내"), MJC)
    assert not {"media_content", "business_marketing"} & set(fields["interest_tags"])
    assert not {"content_creator", "marketer"} & set(fields["related_roles"])


def test_department_name_does_not_set_category():
    fields = RuleBasedAnalyzer().analyze(raw_notice("", title="[모집] 2026-2학기 취ㆍ창업팀 근로학생 모집(화요일)"), MJC)
    assert fields["category"] == "job"


def test_scholarship_tags_come_from_title_only():
    body = "1. 장학 종류: 문화예술 장학, 글로벌 인재 장학, 기계·제조 분야 장학\n2. 제출 서류: 금융거래 확인서"
    plain = RuleBasedAnalyzer().analyze(raw_notice(body, title="2026-2학기 재학생 교내장학종별 장학금 신청 안내"), MJC)
    assert plain["category"] == "scholarship" and plain["interest_tags"] == []
    abroad = RuleBasedAnalyzer().analyze(raw_notice(body, title="화성시인재육성재단 「해외유학 장학금」 안내"), MJC)
    assert abroad["interest_tags"] == ["global_language"]


def test_document_lists_are_not_unresolved_conditions():
    body = "대상: 우리대학 재학생\n제출 서류: 성적증명서 및 통장사본 각 1부\n성적에 관계없이 신청 가능"
    fields = RuleBasedAnalyzer().analyze(raw_notice(body), MJC)
    assert fields["eligibility"]["unresolved_conditions"] == []
    assert fields["eligibility"]["extraction_complete"] is True


@pytest.mark.parametrize(
    "title, expected",
    [
        ("[모집완료] [교수학습센터] 2026-2학기 국가근로장학생 추가 모집", "closed"),
        ("(모집완료)[도서관] 2026-2학기 국가근로장학생 모집", "closed"),
        ("[마감] 선교지원팀 국가근로장학생 모집(주간)", "closed"),
        ("(마감) [교수학습센터] 하계방학 국가근로장학생 모집", "closed"),
        ("[모집 마감]_(생활관운영팀) 2026-1학기 국가근로장학생 모집 완료", "closed"),
        ("[마감임박] 2026 아이디어 경진대회 참가 안내", "open"),
        ("2026 아이디어 경진대회 모집 마감일 연장 안내", "open"),
    ],
)
def test_closed_by_title(title, expected):
    record, _ = record_for(raw_notice(CONTEST, title=title))
    notice, _ = build_notice(record, today=TODAY)
    assert notice["lifecycle_status"] == expected


def test_build_notice_is_schema_valid_and_published():
    record, _ = record_for(raw_notice(CONTEST))
    notice, issues = build_notice(record, today=TODAY)
    assert issues == []
    assert schema_errors("notice", notice) == []
    assert (notice["publication_status"], notice["lifecycle_status"], notice["notice_version"]) == ("published", "open", 1)


def test_closed_after_deadline():
    record, _ = record_for(raw_notice(CONTEST))
    notice, _ = build_notice(record, today=date(2026, 11, 3))
    assert notice["lifecycle_status"] == "closed"


def test_evidence_not_in_source_goes_to_review():
    record, _ = record_for(raw_notice(CONTEST))
    notice, _ = build_notice(record, today=TODAY)
    notice["eligibility"]["conditions"][0]["evidence"] = "원문에 없는 문장"
    assert any("원문에 없는 근거" in i for i in validate(notice, record.raw))


def test_inverted_range_goes_to_review():
    record, _ = record_for(raw_notice("신청기간: 2026.11.20.(금) ~ 2026.11.02.(월)\n우리대학 재학생"))
    notice, issues = build_notice(record, today=TODAY)
    assert notice["publication_status"] == "review_pending"
    assert "application_start가 마감보다 늦음" in issues


def test_change_tracking_and_analysis_reuse():
    record, store = record_for(raw_notice(CONTEST))
    first, _ = build_notice(record, today=TODAY)

    same, _ = build_notice(store.records[record.key], today=TODAY, previous=first)
    assert same["changed_fields"] == [] and same["notice_version"] == 1

    changed_raw = raw_notice(CONTEST.replace("2026.11.02.(월)", "2026.11.09.(월)"), collected_at="2026-10-18T03:00:00Z")
    result = ingest(changed_raw, store)
    second, _ = build_notice(store.records[result.key], today=TODAY, previous=first)
    assert second["notice_version"] == 2
    assert second["changed_fields"] == ["application_deadline"]


def test_unchanged_recollect_refreshes_verified_time():
    """원문이 그대로여도 다시 확인한 시각으로 last_verified_at을 옮긴다 (D-006 오래된 정보 표시)."""
    record, store = record_for(raw_notice(CONTEST))
    first, _ = build_notice(record, today=TODAY)
    ingest(raw_notice(CONTEST, collected_at="2026-10-19T00:00:00Z"), store)
    again, _ = build_notice(store.records[record.key], today=TODAY, previous=first)
    assert again["notice_version"] == 1 and again["changed_fields"] == []
    assert again["last_verified_at"] == again["last_collected_at"] == "2026-10-19T00:00:00Z"


def test_end_to_end_into_recommendation():
    """RawNotice → 파이프라인 → 분석 → 추천까지 연결된다 (합성 데이터)."""
    store = InMemoryStore()
    notices = []
    for body in (CONTEST, "컴퓨터공학과 재학생 대상 소프트웨어 개발자 특강\n신청기간: 2026.10.18.(일) ~ 2026.10.25.(일)"):
        raw = raw_notice(body, source_notice_id=f"BD{len(notices)}", title=f"[합성 샘플] 공고 {len(notices)}")
        result = ingest(raw, store)
        notices.append(build_notice(store.records[result.key], today=TODAY)[0])
    profile = json.loads((ROOT / "fixtures/valid/user_profile/complete.json").read_text(encoding="utf-8"))
    out = recommend(notices, profile, today=TODAY, generated_at="2026-10-17T03:05:00Z")
    assert schema_errors("recommendation_list_response", out) == []
    assert out["items"][0]["notice"]["title"] == "[합성 샘플] 공고 1"


# ---------- 미해석 조건 정리 (D-015) ----------

CTS_LIKE = (
    "2. 지원자격 및 우대사항\n"
    "공통 / ○ 해외여행 결격 사유가 없는 자\n"
    "우대사항 / ○ 외국어 능통자 (토익 850점 이상)\n"
    "○ 근무지 인접 거주자 우대\n"
    "○ 운전면허 소지자\n"
    "3. 지원방법 및 제출서류\n"
    "[이미지 설명]\n"
    "○ 근무지 인접 거주자 우대\n"
)


def test_tidy_unresolved_strips_marks_dedupes_and_marks_preferred():
    from backend.analysis.rules import PREFERRED_NOTE, tidy_unresolved

    lines = CTS_LIKE.splitlines()
    items = [{"evidence": e, "note": None} for e in ("2. 지원자격 및 우대사항", "우대사항 / ○ 외국어 능통자 (토익 850점 이상)", "○ 근무지 인접 거주자 우대")]
    items += [{"evidence": e, "note": "LLM 추출"} for e in ("해외여행 결격 사유가 없는 자", "근무지 인접 거주자 우대", "운전면허 소지자")]
    out, blocked = tidy_unresolved(items, lines)
    assert blocked is False  # 제목 아래에서 항목을 읽었다
    assert [(o["evidence"], o["note"]) for o in out] == [
        ("외국어 능통자 (토익 850점 이상)", PREFERRED_NOTE),
        ("근무지 인접 거주자 우대", PREFERRED_NOTE),
        ("해외여행 결격 사유가 없는 자", "LLM 추출"),
        ("운전면허 소지자", PREFERRED_NOTE),  # '우대사항' 항목 아래 줄
    ]


@pytest.mark.parametrize(
    "line, preferred",
    [
        ("우대사항: 공공분야 법률업무 관련 근무경력", True),
        ("자격요건 및 우대사항은 접수마감일 기준으로 충족해야 함", False),
        ("면접점수가 60점 미만인 경우 우대가점을 포함하더라도 과락 처리", False),
        ("자금운용 / 필수요건: CFA, FRM 중 1개 이상 보유", False),
    ],
)
def test_preferred_only_when_condition_itself_is_preferred(line, preferred):
    from backend.analysis.rules import PREFERRED_NOTE, tidy_unresolved

    out, _ = tidy_unresolved([{"evidence": line, "note": None}], [line])
    assert (out[0]["note"] == PREFERRED_NOTE) is preferred


def test_heading_only_unresolved_keeps_extraction_incomplete():
    fields = RuleBasedAnalyzer().analyze(raw_notice("대상: 우리대학 재학생\n자격요건"), MJC)
    elig = fields["eligibility"]
    assert elig["unresolved_conditions"] == []  # 제목 줄은 체크리스트에 넣지 않는다
    assert elig["extraction_complete"] is False  # 그 아래 조건을 다 읽었다고 볼 수 없다


def test_tidied_evidence_still_passes_source_check():
    record, _ = record_for(raw_notice(CTS_LIKE))
    notice, issues = build_notice(record, today=TODAY)
    assert issues == []
    assert "○" not in "".join(u["evidence"] for u in notice["eligibility"]["unresolved_conditions"])


def test_excluded_status_is_not_read_as_allowed():
    """'휴학생 … 추천 불가'를 재학·휴학 허용으로 읽으면 판정이 뒤집힌다 (D-023)."""
    body = "근로 대상\n- 휴학생 및 정규학기를 초과한 학기의 재학생은 추천 불가\n다. 재등록생, 휴학생 제외/전공심화학생 및 신입생 가능\n"
    elig = RuleBasedAnalyzer().analyze(raw_notice(body), MJC)["eligibility"]
    assert elig["conditions"] == []
    assert [u["evidence"] for u in elig["unresolved_conditions"]] == [
        "휴학생 및 정규학기를 초과한 학기의 재학생은 추천 불가",
        "재등록생, 휴학생 제외/전공심화학생 및 신입생 가능",
    ]
    assert elig["extraction_complete"] is False


def test_abbreviated_enrolled_and_on_leave():
    """'재·휴학생'은 재학생과 휴학생이다. 휴학생만으로 읽으면 재학생이 미충족이 된다."""
    elig = RuleBasedAnalyzer().analyze(raw_notice("참석대상 : 창업동아리 및 재·휴학생\n"), MJC)["eligibility"]
    assert [(c["field"], c["operator"], c["value"]) for c in elig["conditions"]] == [
        ("enrollment_status", "in", ["enrolled", "on_leave"])
    ]


@pytest.mark.parametrize(
    "line",
    [
        "・고등학교 졸업자, 전문대/대학교 졸업자 및 2027년 2월이내 졸업예정자",
        "• 고등학교 졸업이상의 학력 소지자(검정고시 합격자 및 전문대학 졸업자 포함) 또는 2027년 2월 고등학교 졸업예정자",
    ],
)
def test_high_school_or_more_accepts_every_college_status(line):
    """고졸 이상이면 대학생은 재학·휴학·졸업 모두 갖춘다. 졸업생만으로 읽으면 재학생이 미충족이 된다 (D-023)."""
    elig = RuleBasedAnalyzer().analyze(raw_notice(f"지원자격\n{line}\n"), MJC)["eligibility"]
    assert [(c["field"], c["operator"], c["value"]) for c in elig["conditions"]] == [
        ("enrollment_status", "in", ["enrolled", "on_leave", "graduated"])
    ]


def test_high_school_documents_and_graduating_high_schoolers_are_not_conditions():
    body = "제출서류\n· 고등학교 졸업 학력인정 증명서류\n특성화고 관련학과 고등학교 졸업예정자\n"
    elig = RuleBasedAnalyzer().analyze(raw_notice(body), MJC)["eligibility"]
    assert elig["conditions"] == []


PRESENTATION_LINE = "2. 공모대상 : 재학생(전공심화과정 포함) / 개인 또는 팀(2명 이하)"


@pytest.mark.parametrize(
    "text, keep",
    [
        # 지원 자격이 아닌 것: 팀 구성, 주제, 이미 판정한 줄의 일부, 대상을 넓히는 말, 혜택, 일정, 안내
        ("개인 또는 팀(2명 이하)", False),
        ("지정주제 중 택 1", False),
        ("전공심화과정 포함", False),
        ("외국인 유학생 포함", False),
        ("전공심화 학생 신청 가능", False),
        ("장학금 마일리지 10점 적립", False),
        ("공모기간 : ~12.14.(일) 23시 59분까지", False),
        ("관심 있는 학생들", False),
        ("직전학기 12학점 이수", False),  # 규칙이 낸 '직전학기 12학점 이수자'와 같은 조건
        # 신청자 본인 조건
        ("토익 750점 이상(영어 전공학과 800점 이상)", True),
        ("학자금지원구간이 9구간 이내", True),
        ("남자의 경우 병역필 또는 면제자", True),
        ("18세~40세 미만", True),
        ("3월 또는 9월 중 학적변동(휴학 등) 발생자", True),
        ("“국가근로장학사업 승인자”만 가능(학자금지원구간 9구간 이하)", True),
        ("재학생 및 외국유학생", True),
    ],
)
def test_llm_unresolved_keeps_only_applicant_conditions(text, keep):
    from backend.analysis.rules import is_llm_condition

    conditions = [{"field": "enrollment_status", "evidence": PRESENTATION_LINE}]
    unresolved = [{"evidence": "직전학기 12학점 이수자", "note": None}]
    assert is_llm_condition(text, conditions, unresolved) is keep


@pytest.mark.parametrize(
    "line",
    [
        "* 참여혜택 : 성적우수/향상장학금, 마일리지 포인트, 모바일 쿠폰 등",
        "- 1학점은 결석갯수가 4개부터, 2학점은 8개부터, 3학점은 12개부터 F처리 됨",
        "강의평가를 완료하지 않은 경우 [성적조회 및 이의신청] 기간에 성적조회가 불가하오니 참여 부탁드립니다.",
    ],
)
def test_benefit_and_attendance_lines_are_not_unresolved(line):
    elig = RuleBasedAnalyzer().analyze(raw_notice("대상: 우리대학 재학생\n" + line), MJC)["eligibility"]
    assert elig["unresolved_conditions"] == []


def test_llm_preferred_items_are_kept_without_keywords():
    """'우대사항' 항목 아래 줄은 낱말 목록 밖이어도 받는다. 우대 사항으로 따로 묶인다 (D-015, D-023)."""
    from backend.analysis.rules import is_llm_condition

    lines = [
        "우대사항",
        "○ 주말, 야간 촬영 및 외근 등 유연근무 가능자",
        "○ 무관심 또는 거절 고객을 설득해본 경험이 있으신 분",
        "3. 지원방법",
        "○ 취재, 보도 업무에 이해가 있는 자",
    ]
    assert is_llm_condition("주말, 야간 촬영 및 외근 등 유연근무 가능자", [], [], lines) is True
    assert is_llm_condition("무관심 또는 거절 고객을 설득해본 경험이 있으신 분", [], [], lines) is True
    assert is_llm_condition("취재, 보도 업무에 이해가 있는 자", [], [], lines) is False  # 우대 항목 밖, 낱말 없음


# ---------- 공통 규칙 개선 (rule-0.9): 학교와 무관한 합성 문장 ----------

SEWU = source_config("sewu_www_notice")


def cond(fields: dict, field: str):
    return next((c for c in fields["eligibility"]["conditions"] if c["field"] == field), None)


@pytest.mark.parametrize(
    "line",
    ["대상: 우리대학 학생 또는 졸업생 누구나", "대상: 재학생 및 졸업생", "대상: 졸업생 또는 학생"],
)
def test_student_and_graduate_gives_both_statuses(line):
    c = cond(RuleBasedAnalyzer().analyze(raw_notice(line), MJC), "enrollment_status")
    assert c["operator"] == "in" and c["value"] == ["enrolled", "graduated"]


def test_graduate_only_stays_single_value():
    c = cond(RuleBasedAnalyzer().analyze(raw_notice("대상: 졸업생"), MJC), "enrollment_status")
    assert (c["operator"], c["value"]) == ("eq", "graduated")


@pytest.mark.parametrize(
    "line",
    [
        "- 2027년 2월 졸업 예정자 또는 기졸업자로, 풀타임 근무가 가능하신 분",
        "- 기졸업자 또는 2027년 2월 졸업예정자",
        "* 관련 학과 졸업자 및 2027년 2월 졸업 예정인 분",
        "졸업생 및 27년 2월 졸업 예정자",
    ],
)
def test_graduating_students_line_is_checked_by_hand(line):
    """졸업 예정자는 재학생 중 일부라 졸업생만으로 읽지 않고 직접 확인으로 둔다 (D-046)."""
    fields = RuleBasedAnalyzer().analyze(raw_notice("지원자격\n" + line), MJC)
    assert cond(fields, "enrollment_status") is None
    assert any("예정" in u["evidence"] for u in fields["eligibility"]["unresolved_conditions"])  # 글머리표는 정리됨
    assert fields["eligibility"]["extraction_complete"] is False


def test_graduating_included_still_widens_enrolled():
    """'재학생(졸업예정자 포함)'은 재학생 조건 그대로다."""
    c = cond(RuleBasedAnalyzer().analyze(raw_notice("대상: 재학생(졸업예정자 포함)"), MJC), "enrollment_status")
    assert (c["operator"], c["value"]) == ("eq", "enrolled")


def test_high_school_or_more_with_graduating_keeps_all_statuses():
    """고졸 이상 학력 줄은 졸업 예정 문구가 같이 있어도 재학·휴학·졸업 모두 (D-023)."""
    line = "전문대/대학교 졸업자 및 2027년 2월이내 졸업예정자, 고등학교 졸업 이상"
    c = cond(RuleBasedAnalyzer().analyze(raw_notice("지원자격\n" + line), MJC), "enrollment_status")
    assert c["value"] == ["enrolled", "on_leave", "graduated"]


def test_period_with_from_until_uses_end_date_as_deadline():
    body = "※ 수강신청 실시 기간 : 2026. 11. 30. (월), 10:00부터 2026. 12. 03. (목), 23:59까지"
    fields = RuleBasedAnalyzer().analyze(raw_notice(body, title="[알림] 계절학기 운영 공고"), MJC)
    d = fields["application_deadline"]
    assert (d["date"], d["time"], d["precision"]) == ("2026-12-03", "23:59", "minute")
    s = fields["application_start"]
    assert (s["date"], s["time"]) == ("2026-11-30", "10:00")


def test_start_only_from_line_is_not_deadline():
    fields = RuleBasedAnalyzer().analyze(raw_notice("신청은 2026.11.30.(월) 10:00부터 시작합니다"), MJC)
    assert fields["application_deadline"] is None


@pytest.mark.parametrize(
    "line",
    [
        "가. 직전학기 성적 백분위 75점 이상이며 채플 출석 통과자(1차 PASS)",
        "직전학기 평점평균 3.0 이상인 학생",
        "다. 정규학기를 초과하여 재학 중인 초과학기생은 수혜 불가",
        "모든 출품작은 타인의 저작물을 표절·도용하거나, 기존 발표·수상 이력이 있는 작품은 응모할 수 없습니다",
        "타 공모전 수상작은 응모 불가",
    ],
)
def test_applicant_condition_lines_become_unresolved(line):
    elig = RuleBasedAnalyzer().analyze(raw_notice(line), MJC)["eligibility"]
    assert any(line.lstrip("가다. ") in u["evidence"] or u["evidence"] in line for u in elig["unresolved_conditions"])
    assert elig["extraction_complete"] is False


def test_attendance_notice_line_is_not_a_condition():
    elig = RuleBasedAnalyzer().analyze(raw_notice("출석 확인은 현장에서 진행합니다"), MJC)["eligibility"]
    assert elig["unresolved_conditions"] == []


@pytest.mark.parametrize(
    "title",
    ["[입찰공고] 전산 정보보안 운영 인력 용역", "교수 초빙 공고(2027.3.1부)", "전산시스템 보안 업데이트에 따른 서비스 일시 중단 안내"],
)
def test_admin_notice_has_no_conditions(title):
    body = "본교 재학생은 참고 바랍니다\n공고 기간: 2026.11.20.(금) ~ 2026.11.27.(금)"
    fields = RuleBasedAnalyzer().analyze(raw_notice(body, title=title), SEWU)
    assert fields["category"] == "admin_notice"
    elig = fields["eligibility"]
    assert elig["conditions"] == [] and elig["unresolved_conditions"] == []
    assert elig["extraction_complete"] is False and elig["explicitly_unrestricted"] is False
    assert fields["interest_tags"] == []


def test_vendor_contract_notice_has_no_deadline_but_recruitment_keeps_it():
    body = "접수 기간: 2026.11.20.(금) ~ 2026.11.27.(금)"
    bid = RuleBasedAnalyzer().analyze(raw_notice(body, title="[입찰공고] 시설 용역"), SEWU)
    assert bid["application_deadline"] is None and bid["application_start"] is None
    staff = RuleBasedAnalyzer().analyze(raw_notice(body, title="교원 초빙 공고"), SEWU)
    assert staff["application_deadline"]["date"] == "2026-11-27"


def test_staff_hiring_title_with_student_target_is_not_admin():
    plain = RuleBasedAnalyzer().analyze(raw_notice("지원 안내", title="OO센터 직원 채용 공고"), SEWU)
    assert plain["category"] == "admin_notice"
    student = RuleBasedAnalyzer().analyze(raw_notice("지원 안내", title="캠퍼스 리크루팅 직원 채용 설명회"), SEWU)
    assert student["category"] == "job"


@pytest.mark.parametrize("line", ["대상: 본교 재학생(1~4학년)", "대상: 본교 1, 2, 3, 4학년", "대상: 본교 4~1학년 재학생"])
def test_all_grades_listed_means_no_grade_condition(line):
    assert cond(RuleBasedAnalyzer().analyze(raw_notice(line), MJC), "grade") is None


def test_partial_grades_still_conditions():
    assert cond(RuleBasedAnalyzer().analyze(raw_notice("대상: 본교 1, 2, 3학년"), MJC), "grade")["value"] == [1, 2, 3]
    assert cond(RuleBasedAnalyzer().analyze(raw_notice("대상: 본교 2~3학년"), MJC), "grade")["value"] == [2, 3]


def test_own_school_name_before_status_is_university_condition():
    for line in ("대상: 숭의여자대학교 재학생 40명", "대상: 숭의여자대학교 학생 또는 졸업생 누구나"):
        assert cond(RuleBasedAnalyzer().analyze(raw_notice(line), SEWU), "university_id")["value"] == "sewu"
    greeting = RuleBasedAnalyzer().analyze(raw_notice("숭의여자대학교 학생 여러분을 기다립니다"), SEWU)
    assert cond(greeting, "university_id") is None


@pytest.mark.parametrize(
    ("title", "category"),
    [
        ("[봉사단] 초등학생 놀이대회 자원봉사자 모집 안내", "volunteer"),
        ("[센터] 창의성 발견하기 특강 프로그램 안내", "education_program"),
        ("[센터] 역량기반 창의성 특강", "education_program"),
        ("실전직무 부트캠프 모집", "education_program"),
        ("[알림] 계절학기 수업 운영 계획 시행공고", "academic"),
        ("[봉사단] 텀블러 세척기 OPEN", "admin_notice"),
        ("전산시스템 점검에 따른 서비스 중단 안내", "admin_notice"),
        ("[공모전] 창업 아이디어 공모전", "contest"),
    ],
)
def test_category_rules(title, category):
    assert RuleBasedAnalyzer().analyze(raw_notice("안내드립니다", title=title), SEWU)["category"] == category


@pytest.mark.parametrize("fallback", [False, True])
def test_poster_changes_publish_without_reanalysis(monkeypatch, fallback):
    from backend.publish import InMemorySink, publish

    raw = raw_notice(CONTEST)
    fields = dict(raw["source_fields"])
    first_url = fields.pop("poster_url")
    raw["source_fields"] = fields
    record, store = record_for(raw)
    previous, issues = build_notice(record, today=TODAY)
    # 이미 본문 변경 이력이 있는 게시본에서도 이력을 유지한다.
    previous["changed_fields"] = ["title"]
    sink = InMemorySink()
    publish(previous, issues, sink)
    analyzer = RuleBasedAnalyzer()
    if fallback:
        monkeypatch.setattr(analyzer, "version", analyzer.version + "+ollama:test")
    monkeypatch.setattr(analyzer, "analyze", lambda *_: pytest.fail("poster update invoked analyzer"))
    for url in (first_url, first_url.replace("sample-", "updated-"), None):
        incoming = dict(raw, source_fields=dict(fields, **({"poster_url": url} if url else {})))
        assert content_hash(incoming) == raw["content_hash"]
        result = ingest(incoming, store)
        assert result.notice_version == 1
        notice, issues = build_notice(store.get(result.key), today=TODAY, previous=previous, analyzer=analyzer)
        publish(notice, issues, sink)
        public = dict(sink.get_public(notice["notice_id"]))
        assert ("poster_url" in public) == bool(url)
        assert public.pop("poster_url", None) == url
        assert public == {k: v for k, v in previous.items() if k != "poster_url"}
        previous = notice
