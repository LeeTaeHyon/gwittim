"""상세 분석 공고 본문 입력 (docs/agent-detail-body-spec.md §4.2~4.4, §6.1)."""
import json
from datetime import date
from pathlib import Path

from backend.agent import prompt
from backend.agent.prompt import (
    BODY_MAX_CHARS, BODY_TRUNCATED_MARK, SKILLS_UNKNOWN, body_for_model, build_messages, ground_report,
)
from backend.agent.tests.test_prompt import NOTICE, PAYLOAD

TODAY = date(2026, 11, 24)
VERDICT = ("needs_check", [])
HARNESS = Path(prompt.__file__).resolve().parent / "harness" / "detail_analysis.md"
EVAL_COPY = Path(prompt.__file__).resolve().parents[2] / "tools" / "agent_eval_variants" / "detail_d3.md"
EXTRA_SENTENCE = "- 입력에 '본문'이 없으면 요약과 조건만으로 씁니다."


def _public(user: str) -> dict:
    return json.loads(user)["공고"]


def test_body_goes_under_notice_and_other_fields_stay():
    _, without = build_messages(NOTICE, PAYLOAD, VERDICT, TODAY)
    _, with_body = build_messages(NOTICE, PAYLOAD, VERDICT, TODAY, body="  일시: 12월 3일 14시\n장소: 본관 301호  ")
    assert _public(with_body)["본문"] == "일시: 12월 3일 14시\n장소: 본관 301호"
    rest = {k: v for k, v in _public(with_body).items() if k != "본문"}
    assert rest == _public(without)
    assert json.loads(with_body)["학생"] == json.loads(without)["학생"]


def test_body_field_is_last_in_notice_like_eval_input():
    """평가 D3 입력과 같은 순서: 본문은 공고 칸의 마지막."""
    _, user = build_messages(NOTICE, PAYLOAD, VERDICT, TODAY, body="본문입니다. 스무 자가 넘는 본문 내용.")
    assert list(_public(user))[-1] == "본문"


def test_body_missing_drops_field():
    for body in (None, "", "   \n "):
        _, user = build_messages(NOTICE, PAYLOAD, VERDICT, TODAY, body=body)
        assert "본문" not in _public(user)


def test_long_body_is_cut_with_marker():
    text, state = body_for_model("가" * 5000)
    assert state == "truncated" and len(text) == BODY_MAX_CHARS == 4000
    _, user = build_messages(NOTICE, PAYLOAD, VERDICT, TODAY, body="가" * 5000)
    assert _public(user)["본문"] == "가" * 4000 + BODY_TRUNCATED_MARK
    assert body_for_model("가" * 4000) == ("가" * 4000, "present")
    _, user = build_messages(NOTICE, PAYLOAD, VERDICT, TODAY, body="가" * 4000)
    assert _public(user)["본문"] == "가" * 4000  # 정확히 4,000자는 표시 없음
    assert body_for_model(None) == (None, "absent")


# ---------- 역량 줄 근거 ----------

def _notice(unresolved=()):
    return {
        "eligibility": {"unresolved_conditions": [{"evidence": e, "note": n} for e, n in unresolved]},
        "application_deadline": None,
    }


def _report(skills):
    return {"fit": "맞음: 겹침", "eligibility": "확인 필요: 조건", "todo": "확인합니다.", "skills": skills}


def test_skill_line_kept_when_body_has_support_and_dropped_otherwise():
    body = "지원 자격\n파이썬으로 데이터 분석을 해 본 경험\n발표 일정 안내"
    out, ch = ground_report(_report("파이썬 데이터 분석\n영상 편집 능력"), _notice(), "needs_check", TODAY, body=body)
    assert out["skills"] == "파이썬 데이터 분석"
    assert ch == {"skills_dropped": 1}


def test_skill_preferred_mark_only_from_original_conditions():
    notice = _notice([("AI를 활용해 결과물을 직접 만들어 본 경험이 있는 분", "우대 사항")])
    body = "신청서 제출 안내\n토익 750점 이상 필요"
    out, _ = ground_report(_report("AI를 활용한 결과물 제작\n토익 750점 이상 (우대)"), notice, "needs_check", TODAY, body=body)
    # 앞 줄은 원래 조건(우대 사항)이 먼저 맞아 우대, 토익은 본문 줄에서만 맞아 우대를 붙이지 않고 모델 표시도 뗀다
    assert out["skills"].split("\n") == ["AI를 활용한 결과물 제작 (우대)", "토익 750점 이상"]


def test_without_body_grounding_is_unchanged():
    notice = _notice([("토익 750점 이상", None)])
    report = _report("토익 750점 이상\n파이썬 데이터 분석")
    assert ground_report(report, notice, "needs_check", TODAY) == ground_report(report, notice, "needs_check", TODAY, body=None)
    out, ch = ground_report(report, notice, "needs_check", TODAY)
    assert out["skills"] == "토익 750점 이상" and ch == {"skills_dropped": 1}
    out, _ = ground_report(_report("파이썬 데이터 분석"), _notice(), "needs_check", TODAY)
    assert out["skills"] == SKILLS_UNKNOWN


# ---------- 지침 파일 ----------

def test_harness_differs_from_eval_copy_by_one_sentence_only():
    ours = HARNESS.read_text(encoding="utf-8").splitlines()
    theirs = EVAL_COPY.read_text(encoding="utf-8").splitlines()
    assert [ln for ln in ours if ln != EXTRA_SENTENCE] == theirs
    assert ours.count(EXTRA_SENTENCE) == 1


def test_harness_version_bumped():
    assert prompt.HARNESS_VERSION == "detail-2026-11-24.1"
