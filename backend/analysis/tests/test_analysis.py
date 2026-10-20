import json
from datetime import date
from pathlib import Path

from backend.analysis import RuleBasedAnalyzer, build_notice, validate
from backend.collectors.common import InMemoryStore, content_hash, ingest
from backend.contracts import schema_errors
from backend.recommendation import recommend
from backend.sources import source_config

ROOT = Path(__file__).resolve().parents[3]
TODAY = date(2026, 10, 17)
MJC = source_config("mjc_www_notice")


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


def test_no_conditions_found_is_not_unrestricted():
    elig = RuleBasedAnalyzer().analyze(raw_notice("많은 참여 바랍니다."), MJC)["eligibility"]
    assert (elig["conditions"], elig["explicitly_unrestricted"], elig["extraction_complete"]) == ([], False, False)


def test_explicitly_unrestricted():
    elig = RuleBasedAnalyzer().analyze(raw_notice("학년·학과 제한 없이 누구나 참여 가능"), MJC)["eligibility"]
    assert elig["explicitly_unrestricted"] is True
    assert elig["unrestricted_evidence"] == "학년·학과 제한 없이 누구나 참여 가능"


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
