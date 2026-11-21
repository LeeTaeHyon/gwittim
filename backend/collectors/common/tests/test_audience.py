import pytest

from backend.collectors.common.audience import audience_verdict
from backend.collectors.common.external import SeenLog, mask_contacts


@pytest.mark.parametrize(
    "text",
    ["대학생", "대학(원)생", "대학생, 대학원생", "청년", "누구나", "제한 없음", "제한없음", "일반인", "성인",
     "누구나, 유치원, 초등학생, 중학생, 고등학생, 대학생", "중학생, 고등학생, 대학생, 일반인"],
)
def test_included(text):
    assert audience_verdict(text).include


@pytest.mark.parametrize("text", ["청소년", "청소년, 어린이", "초등학생", "중학생, 고등학생", "초·중·고등학생", "유치원, 초등학생", "일반고 학생"])
def test_excluded_only_when_all_minor(text):
    v = audience_verdict(text)
    assert not v.include and "제외" in v.reason


@pytest.mark.parametrize("text", [None, "", "  ", "기타", "직장인", "외국인", "해당자 ▶"])
def test_ambiguous_is_included(text):
    assert audience_verdict(text).include


def test_mask_contacts_keeps_dates():
    out = mask_contacts("접수 2026-12-01 ~ 2026.12.20 문의 a@b.co 02-123-4567, 010-1234-5678, 1588-1234")
    assert "2026-12-01" in out and "2026.12.20" in out
    assert "a@b.co" not in out and "123-4567" not in out and "1588" not in out


def test_seen_log_roundtrip(tmp_path):
    log = SeenLog(tmp_path / "x" / "seen.json")
    log.add("s:1", "이유")
    log.save()
    assert SeenLog(tmp_path / "x" / "seen.json").has("s:1")
