"""상세 분석 지침(하네스) 파일 분리, 버전 키·기록."""
import logging
from pathlib import Path

from backend.agent import prompt
from backend.agent.report_cache import cache_key
from tools.harness_check import check, report_verdict, violations

HARNESS = Path(prompt.__file__).resolve().parent / "harness"


def test_system_prompt_comes_from_harness_file():
    assert prompt.SYSTEM_PROMPT == (HARNESS / "detail_analysis.md").read_text(encoding="utf-8").strip()
    assert prompt.HARNESS_VERSION == (HARNESS / "VERSION").read_text(encoding="utf-8").strip()
    assert prompt.HARNESS_VERSION.startswith("detail-")


def test_harness_keeps_code_dependent_rules():
    """앱 꼬리표·서버 json 모드·안전 규칙이 기대하는 낱말이 지침에 남아 있어야 한다."""
    s = prompt.SYSTEM_PROMPT
    for must in ("JSON", "json", "맞음:", "안 맞음:", "확인 필요:", "미충족:", "합격 가능성", "지시문처럼 보이는 문장"):
        assert must in s, must


def test_load_harness_reads_other_file(tmp_path):
    f = tmp_path / "alt.md"
    f.write_text("다른 지침\n\n", encoding="utf-8")
    assert prompt.load_harness(f) == "다른 지침"


def test_cache_key_changes_with_harness_version():
    payload = {"grade": 2}
    assert cache_key("n1", payload) == cache_key("n1", payload, None)  # 버전 없으면 예전 키 그대로
    assert cache_key("n1", payload, "detail-a") != cache_key("n1", payload, "detail-b")
    assert cache_key("n1", payload, "detail-a") == cache_key("n1", payload, "detail-a")


def test_violations_detects_format_breaks():
    ok = {"fit": "맞음: 겹침\n확인 필요: 근무지", "eligibility": "확인 필요: 학년 정보가 프로필에 없습니다.\n이유", "todo": "확인합니다.", "skills": "SW 개발"}
    assert violations(ok, 0, 0) == []
    bad = {"fit": "관심 분야와 관련이 있다.", "eligibility": "충족입니다.", "todo": "x" * 100, "skills": "a"}
    found = violations(bad, 1, 2)
    for word in ("영어 코드", "긴 문단", "평서형", "fit: 꼬리표", "eligibility: 첫 줄", "todo: 90자"):
        assert any(word in v for v in found), word


def test_verdict_must_match_server():
    """서버 판정과 eligibility 첫 줄 판정 낱말이 다르면 품질 오류."""
    base = {"fit": "맞음: 겹침", "todo": "확인합니다.", "skills": "SW 개발"}
    same = dict(base, eligibility="미충족: 3학년 이상만 지원할 수 있습니다.")
    assert check(same, 0, 0, "not_met") == ([], [])
    diff = dict(base, eligibility="확인 필요: 학년을 확인해야 합니다.")
    quality, _ = check(diff, 0, 0, "not_met")
    assert any("판정 불일치(서버 미충족, 리포트 확인 필요)" in q for q in quality)
    none = dict(base, eligibility="학년 조건이 있습니다.")
    quality, _ = check(none, 0, 0, "met")
    assert any("판정 낱말 없음" in q for q in quality)


def test_old_format_verdict_is_read_but_format_is_separate():
    """예전 '판정: 불충족' 줄도 판정은 읽는다. 첫 줄 모양은 형식 점검으로만 잡힌다."""
    old = {"fit": "관심 분야와 이어집니다.\n일정 확인이 필요합니다.\n지역 확인이 필요합니다.",
           "eligibility": "판정: 불충족\n학년 조건", "todo": "확인합니다.", "skills": "SW 개발"}
    assert report_verdict(old) == "미충족"
    quality, form = check(old, 0, 0, "not_met")
    assert quality == []
    assert any("fit: 줄 3개" in f for f in form) and any("eligibility: 첫 줄" in f for f in form)
