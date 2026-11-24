"""자체 공고 줄 분류 모델 분석기(D-042)의 합치기 규칙. 가짜 예측기를 넣으므로 torch·가중치 불필요.

마지막 시험만 실제 가중치(data/local/models/extract-v1)와 torch가 있을 때 돈다.
"""
import copy
import json
from datetime import date
from pathlib import Path

import pytest

from backend.analysis import build_notice
from backend.analysis.extract_model import MODEL_NOTE, ExtractModelAnalyzer, model_lines
from backend.analysis.kakao import KakaoAnalyzer
from backend.analysis.rules import ANALYSIS_VERSION
from backend.collectors.common import InMemoryStore, content_hash, ingest
from backend.contracts import schema_errors
from backend.sources import source_config

ROOT = Path(__file__).resolve().parents[3]
MJC = source_config("mjc_www_notice")
KAKAO = source_config("mjc_kakao")
LABELS = ["deadline", "qual", "pref", "uni_mjc", "enr_enrolled", "enr_on_leave", "enr_graduated",
          "grade_1", "grade_2", "grade_3", "grade_4"]
THRESHOLDS = {n: 0.5 for n in LABELS} | {"deadline": 0.9}


class FakePredictor:
    """줄에 들어 있는 문구로 꼬리표를 정한다. 받은 줄을 기록한다."""

    def __init__(self, rules: dict[str, dict[str, float]]):
        self.rules = rules
        self.seen: list[list[str]] = []

    def __call__(self, lines):
        self.seen.append(lines)
        out = []
        for line in lines:
            row = [0.01] * len(LABELS)
            for phrase, tags in self.rules.items():
                if phrase in line:
                    for name, p in tags.items():
                        row[LABELS.index(name)] = p
            out.append(row)
        return out


def analyzer(rules, base=None):
    return ExtractModelAnalyzer(FakePredictor(rules), LABELS, THRESHOLDS, "extract-test", base)


def raw(body, title="[합성 샘플] 교내 프로그램 모집", source="mjc_board_date_only.json"):
    r = json.loads((ROOT / "fixtures/valid/raw_notice" / source).read_text(encoding="utf-8"))
    r.update(title=title, body_text=body, attachments=[])
    r["content_hash"] = content_hash(r)
    return r


BODY = (
    "프로그램 안내 2026.11.01.(일) 공개\n"
    "신청기간: 2026.11.02.(월) ~ 2026.11.13.(금)\n"
    "문의: 합성팀 02-300-1234\n"
    "대상: 재학생\n"
    "직전 학기 평점 3.0 이상\n"
    "토익 700점 이상 우대\n"
)


def test_deadline_comes_from_model_line_with_range_start():
    a = analyzer({"신청기간": {"deadline": 0.99}})
    f = a.analyze(raw(BODY), MJC)
    assert f["application_deadline"]["date"] == "2026-11-13"
    assert f["application_start"]["date"] == "2026-11-02"
    assert f["application_deadline"]["evidence"] == "신청기간: 2026.11.02.(월) ~ 2026.11.13.(금)"
    assert a.version == f"{ANALYSIS_VERSION}+extract-test" and "_analysis_version" not in f


def test_no_model_deadline_means_unknown_even_if_rules_found_one():
    # 규칙은 '마감' 줄을 마감으로 읽지만, 모델이 문턱을 넘는 줄을 고르지 않으면 미상으로 둔다
    body = "접수 마감 2026.11.20.(금)\n대상: 재학생\n"
    rule_only = ExtractModelAnalyzer(FakePredictor({}), LABELS, THRESHOLDS, "x").base.analyze(raw(body), MJC)
    assert rule_only["application_deadline"]["date"] == "2026-11-20"
    f = analyzer({"접수 마감": {"deadline": 0.6}}).analyze(raw(body), MJC)
    assert f["application_deadline"] is None and f["application_start"] is None


def test_model_sees_redacted_lines_but_evidence_is_original():
    a = analyzer({"문의처": {"deadline": 0.95}})
    f = a.analyze(raw(BODY + "마감: 문의처 02-300-1234 2026.11.30.(월)까지\n"), MJC)
    assert all("02-300-1234" not in l for l in a.predictor.seen[0])
    assert "02-300-1234" in f["application_deadline"]["evidence"]  # 근거는 원문 그대로라 검증을 통과한다
    assert a.predictor.seen[0][0] == "[합성 샘플] 교내 프로그램 모집"  # 첫 줄은 제목 (학습 때와 같게)


def test_model_fills_only_condition_fields_rules_missed():
    body = "대상: 재학생\n졸업생도 신청할 수 있음\n본교 2학년 대상\n"
    a = analyzer({"졸업생": {"enr_graduated": 0.9}, "2학년": {"grade_2": 0.9, "uni_mjc": 0.9}})
    f = a.analyze(raw(body), MJC)
    conds = {c["field"]: c for c in f["eligibility"]["conditions"]}
    assert conds["enrollment_status"]["value"] == "enrolled"  # 규칙이 찾은 필드는 그대로
    assert conds["grade"]["evidence"] == "본교 2학년 대상"  # 규칙이 이미 찾음
    assert conds["university_id"]["value"] == "mjc"


def test_model_condition_values_and_operator():
    body = "지원 대상은 재학 중이거나 졸업한 사람\n"
    f = analyzer({"지원 대상": {"enr_graduated": 0.8, "enr_enrolled": 0.8}}).analyze(raw(body), MJC)
    (c,) = f["eligibility"]["conditions"]
    assert c == {"field": "enrollment_status", "operator": "in", "value": ["enrolled", "graduated"],
                 "evidence": "지원 대상은 재학 중이거나 졸업한 사람", "validation_status": "validated"}
    assert f["eligibility"]["explicitly_unrestricted"] is False


def test_exclusion_lines_never_become_allow_conditions():
    body = "휴학생 및 정규학기 초과 재학생 지원불가\n"
    f = analyzer({"지원불가": {"enr_enrolled": 0.95}}).analyze(raw(body), MJC)
    assert not f["eligibility"]["conditions"]
    assert any("지원불가" in u["evidence"] for u in f["eligibility"]["unresolved_conditions"])  # 규칙이 직접 확인으로 낸다


def test_other_condition_lines_are_added_and_tidied():
    body = "1. 신청 자격: 직전 학기 이수 15학점 이상\n○ 해외 체류 경험자 우대\n"
    a = analyzer({"이수 15학점": {"qual": 0.9}, "해외 체류": {"pref": 0.9}})
    f = a.analyze(raw(body), MJC)
    items = {u["evidence"]: u["note"] for u in f["eligibility"]["unresolved_conditions"]}
    assert "해외 체류 경험자 우대" in items and items["해외 체류 경험자 우대"] == "우대 사항"
    assert any("이수 15학점 이상" in e for e in items)
    assert len(items) == 2  # 규칙이 낸 문구와 겹치면 하나로
    assert f["eligibility"]["extraction_complete"] is False


def test_model_only_line_gets_model_note():
    body = "온라인 사전 교육을 마친 사람만 신청\n"
    f = analyzer({"사전 교육": {"qual": 0.9}}).analyze(raw(body), MJC)
    assert f["eligibility"]["unresolved_conditions"] == [{"evidence": "온라인 사전 교육을 마친 사람만 신청", "note": MODEL_NOTE}]


def test_predictor_failure_falls_back_to_rules():
    def broken(lines):
        raise RuntimeError("모델 없음")

    a = ExtractModelAnalyzer(broken, LABELS, THRESHOLDS, "extract-test")
    f = a.analyze(raw(BODY), MJC)
    assert f["_analysis_version"] == ANALYSIS_VERSION and a.model_failed == 1
    assert f["application_deadline"]["date"] == "2026-11-13"  # 규칙 결과 그대로


def test_board_yearless_deadline_read_near_published_date():
    # 게시판 공고도 모델이 고른 줄에 연도가 없으면 게시일(fixture: 2026-10-15) 기준으로 읽는다
    body = "양식을 작성해 11월 15일(일) 23:59까지 보내 주셔야 접수됩니다\n"
    f = analyzer({"23:59까지": {"deadline": 0.99}}).analyze(raw(body), MJC)
    assert f["application_deadline"]["date"] == "2026-11-15"
    assert f["application_deadline"]["time"] == "23:59"


def test_kakao_yearless_deadline_and_no_rule_refill():
    r = raw("특강 신청: 11월 9일(월)까지\n특강 일시: 11월 16일(월) 15시\n", title="[합성 샘플] 특강 안내", source="kakao_no_url.json")
    f = KakaoAnalyzer(analyzer({"특강 신청": {"deadline": 0.99}})).analyze(r, KAKAO)
    assert f["application_deadline"]["date"] == "2026-11-09"
    assert f["activity_period"]["start"]["date"] == "2026-11-16"  # 활동 기간은 그대로 날짜 규칙이 채운다
    # 모델이 마감 줄을 고르지 않으면 알림톡 날짜 규칙도 마감을 메우지 않는다
    f = KakaoAnalyzer(analyzer({})).analyze(r, KAKAO)
    assert f["application_deadline"] is None
    assert KakaoAnalyzer().analyze(r, KAKAO)["application_deadline"]["date"] == "2026-11-09"  # 모델 없으면 예전대로


def test_model_notice_passes_validation():
    store = InMemoryStore()
    result = ingest(raw(BODY + "졸업생도 신청할 수 있음\n"), store)
    a = analyzer({"신청기간": {"deadline": 0.99}, "평점": {"qual": 0.9}, "졸업생도": {"enr_graduated": 0.9}})
    notice, issues = build_notice(store.records[result.key], today=date(2026, 10, 17), analyzer=a)
    assert issues == [] and schema_errors("notice", notice) == []
    assert notice["analysis_version"] == a.version


def test_graduating_line_is_not_enrollment_condition_from_model():
    # D-046: '졸업 예정자' 줄은 규칙이 직접 확인으로 보낸다. 모델이 졸업생 꼬리표를 붙여도 재학 상태 조건이 되지 않는다
    body = "신청 자격: 기졸업자 또는 졸업예정자\n"
    a = analyzer({"졸업예정자": {"enr_graduated": 0.95}})
    f = a.analyze(raw(body), MJC)
    elig = f["eligibility"]
    assert not any(c["field"] == "enrollment_status" for c in elig["conditions"])
    assert any("졸업예정자" in u["evidence"] for u in elig["unresolved_conditions"])  # 규칙의 직접 확인 조건은 남는다
    assert elig["extraction_complete"] is False


def test_admin_notice_skips_model_entirely():
    # 업체 계약 공고: 규칙이 마감·조건을 비운다. 모델이 꼬리표를 붙여도 되살리지 않고, 모델 집계에도 넣지 않는다
    body = "공고 기간: 2026.11.20.(금) ~ 2026.11.27.(금)\n대상: 재학생\n참가 자격: 사업자등록증 보유 업체\n"
    a = analyzer({"공고 기간": {"deadline": 0.99}, "대상": {"enr_enrolled": 0.95}, "참가 자격": {"qual": 0.95}})
    f = a.analyze(raw(body, title="[입찰공고] 전산 정보보안 운영 인력 용역"), MJC)
    assert f["category"] == "admin_notice"
    assert f["application_deadline"] is None and f["application_start"] is None
    elig = f["eligibility"]
    assert elig["conditions"] == [] and elig["unresolved_conditions"] == []
    assert a.model_analyzed == 0 and a.predictor.seen == []


def test_all_grades_from_model_is_not_a_grade_condition():
    # 모델이 1~4학년을 모두 모으면 제한이 아니다(규칙의 '학년 전체 나열 무시'와 같음). 일부 학년이면 그대로 조건
    body = "1~4학년 누구나 참여 가능\n"
    f = analyzer({"누구나": {f"grade_{g}": 0.9 for g in (1, 2, 3, 4)}}).analyze(raw(body), MJC)
    assert not any(c["field"] == "grade" for c in f["eligibility"]["conditions"])
    f = analyzer({"참여 학년": {"grade_2": 0.9, "grade_3": 0.9}}).analyze(raw("참여 학년 안내\n"), MJC)
    (c,) = [c for c in f["eligibility"]["conditions"] if c["field"] == "grade"]
    assert c["operator"] == "in" and c["value"] == [2, 3]


def test_school_tag_only_counts_for_matching_source_school():
    body = "명지 소속 대상 프로그램\n"
    rules = {"소속": {"uni_mjc": 0.95}}
    f = analyzer(rules).analyze(raw(body), MJC)
    assert [c["value"] for c in f["eligibility"]["conditions"] if c["field"] == "university_id"] == ["mjc"]
    sewu = source_config("sewu_www_notice")
    f = analyzer(rules).analyze(raw(body), sewu)
    assert not any(c["field"] == "university_id" for c in f["eligibility"]["conditions"])


def test_model_lines_match_training_split():
    assert model_lines({"title": "  제목 ", "body_text": "첫 줄\n\n  둘째 줄  \n"}) == ["제목", "첫 줄", "둘째 줄"]


MODEL_DIR = ROOT / "data/local/models/extract-v1"


@pytest.mark.skipif(not (MODEL_DIR / "model.safetensors").exists(), reason="가중치 없음 (저장소에 넣지 않음)")
def test_real_weights_load_and_predict():
    pytest.importorskip("torch")
    a = ExtractModelAnalyzer.load(MODEL_DIR)
    f = a.analyze(raw(BODY), MJC)
    assert a.model_analyzed == 1
    assert f["application_deadline"]["date"] == "2026-11-13"
    assert copy.deepcopy(f) == a.analyze(raw(BODY), MJC)  # 같은 입력이면 같은 결과
