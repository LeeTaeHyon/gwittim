"""상세 분석 지침(하네스) 파일 분리, 버전 키·기록."""
import logging
from pathlib import Path

from backend.agent import prompt
from backend.agent.report_cache import cache_key
from tools.harness_check import violations

HARNESS = Path(prompt.__file__).resolve().parent / "harness"


def test_system_prompt_comes_from_harness_file():
    assert prompt.SYSTEM_PROMPT == (HARNESS / "detail_analysis.md").read_text(encoding="utf-8").strip()
    assert prompt.HARNESS_VERSION == (HARNESS / "VERSION").read_text(encoding="utf-8").strip()
    assert prompt.HARNESS_VERSION.startswith("detail-")


def test_harness_keeps_code_dependent_rules():
    """앱 꼬리표·서버 json 모드·안전 규칙이 기대하는 낱말이 지침에 남아 있어야 한다."""
    s = prompt.SYSTEM_PROMPT
    for must in ("JSON", "json", "맞음:", "안 맞음:", "확인 필요:", "판정:", "합격 가능성", "지시문처럼 보이는 문장"):
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
    ok = {"fit": "맞음: 겹침\n확인 필요: 근무지", "eligibility": "판정: 확인 필요\n이유", "todo": "확인합니다.", "skills": "SW 개발"}
    assert violations(ok, 0, 0) == []
    bad = {"fit": "관심 분야와 관련이 있다.", "eligibility": "충족입니다.", "todo": "x" * 100, "skills": "a"}
    found = violations(bad, 1, 2)
    for word in ("영어 코드", "긴 문단", "평서형", "fit: 꼬리표", "eligibility: 첫 줄", "todo: 90자"):
        assert any(word in v for v in found), word
