"""알림톡 수집(D-016)을 합성 카톡 내보내기 파일로 검증한다. 실제 대화는 쓰지 않는다."""
from datetime import date

from backend.analysis.kakao import KakaoAnalyzer
from backend.batch import run_kakao
from backend.collectors.common import InMemoryStore, notice_key
from backend.collectors.mjc_kakao.adapter import to_raw_notices
from backend.collectors.mjc_kakao.parser import read_exports
from backend.contracts import schema_errors
from backend.publish import InMemorySink
from backend.sources import source_config

ROOM = "명지전문대학 합성채널"
HEADER = f"{ROOM} 님과 카카오톡 대화\n저장한 날짜 : 2026-10-30 10:00:00\n"


def day(d: str) -> str:
    return f"\n--------------- {d} ---------------\n"


def msg(time: str, text: str) -> str:
    return f"[{ROOM}] [{time}] {text}\n"


EXPORT = (
    HEADER
    + day("2026년 10월 20일 화요일")
    + msg("오후 2:05", "[합성 샘플] 2026 교내 AI 데이터 분석 경진대회 참가팀 모집\n대상: 재학생\n신청기간: 2026.10.20.(화) ~ 2026.11.13.(금)")
    + msg("오후 3:00", "[합성 샘플] 명지튜터링에 신청해 주셔서 감사합니다. 승인 결과를 안내드립니다.")
    + msg("오후 4:00", "[합성 샘플] 데이터베이스 801반 강의를 아직 수강하지 않았습니다.")
    + day("2026년 10월 22일 목요일")
    # 같은 공지 재발송: 묶여서 공고 하나가 된다
    + msg("오전 9:00", "[합성 샘플] 2026 교내 AI 데이터 분석 경진대회 참가팀 모집\n대상: 재학생\n신청기간: 2026.10.20.(화) ~ 2026.11.13.(금)")
    + msg("오전 10:00", "[합성 샘플] 겨울방학 영어 회화 프로그램 안내\n문의: 010-1234-5678")
)


def export_dir(tmp_path, text=EXPORT):
    path = tmp_path / f"KakaoTalk_20261030_1000_00_000_{ROOM}.txt"
    path.write_text(text, encoding="utf-8")
    return [str(path)]


def test_only_broadcast_groups_become_raw_notices(tmp_path):
    raws = to_raw_notices(export_dir(tmp_path), collected_at="2026-10-30T01:00:00Z")
    assert [r["title"] for r in raws] == [
        "[합성 샘플] 2026 교내 AI 데이터 분석 경진대회 참가팀 모집",
        "[합성 샘플] 겨울방학 영어 회화 프로그램 안내",
    ]
    for r in raws:
        assert schema_errors("raw_notice", r) == []
        assert r["source_url"] is None and r["source_notice_id"]
        assert r["published"]["timezone"] == "Asia/Seoul"
    assert raws[0]["published"]["date"] == "2026-10-20" and raws[0]["published"]["time"] == "14:05"
    assert "<휴대폰>" in raws[1]["body_text"] and "010-1234" not in raws[1]["body_text"]


def test_kinds(tmp_path):
    msgs, groups = read_exports(export_dir(tmp_path))
    assert [m["kind"] for m in msgs] == ["broadcast", "participant", "personal_course", "broadcast", "broadcast"]
    assert len(groups) == 4  # 재발송은 첫 공지와 같은 묶음


def test_id_stays_when_later_export_has_more_messages(tmp_path):
    (tmp_path / "a").mkdir()
    first = to_raw_notices(export_dir(tmp_path / "a"))
    longer = EXPORT + day("2026년 10월 29일 목요일") + msg("오전 9:00", "[합성 샘플] 도서관 독서 감상문 공모전 안내")
    (tmp_path / "b").mkdir()
    second = to_raw_notices(export_dir(tmp_path / "b", longer))
    assert [notice_key(r) for r in first] == [notice_key(r) for r in second[:2]]
    assert [r["content_hash"] for r in first] == [r["content_hash"] for r in second[:2]]


def test_run_kakao_publishes_with_model_tags_and_gemma_fallback(tmp_path):
    raws = to_raw_notices(export_dir(tmp_path), collected_at="2026-10-30T01:00:00Z")
    calls = []

    def broken_gemma(title, text):
        calls.append(title)
        raise TimeoutError

    analyzer = KakaoAnalyzer(gemma=broken_gemma)
    store, sink, notices = InMemoryStore(), InMemorySink(), {}
    report = run_kakao(raws, store=store, sink=sink, notices=notices, today=date(2026, 10, 30), analyzer=analyzer)
    assert report.collected == 2 and report.published == 2
    for n in sink.public.values():
        assert schema_errors("notice", n) == []
        assert n["source_url"] is None
    ai = next(n for n in sink.public.values() if "AI" in n["title"])
    assert "ai_data" in ai["interest_tags"]
    assert ai["application_deadline"]["date"] == "2026-11-13" and ai["lifecycle_status"] == "open"
    # 애매해서 Gemma를 불렀지만 실패한 공고는 내 모델 결과로 게시하고, 다음 배치 때 다시 분석되도록 버전을 다르게 남긴다
    if calls:
        assert analyzer.decided_by["model_gemma_failed"] == len(calls)
        assert any(n["analysis_version"].endswith("-nogemma") for n in sink.public.values())

    # 같은 내보내기를 다시 넣으면 수정본으로 보지 않는다
    again = run_kakao(raws, store=store, sink=sink, notices=notices, today=date(2026, 10, 30), analyzer=KakaoAnalyzer())
    assert again.outcomes["unchanged"] == 2


def test_gemma_answer_replaces_model_when_unsure(tmp_path):
    raws = to_raw_notices(export_dir(tmp_path), collected_at="2026-10-30T01:00:00Z")
    gemma = lambda title, text: {"interest_ids": ["global_language"], "category": "global", "for_all_students": False, "reason": ""}
    analyzer = KakaoAnalyzer(gemma=gemma)
    fields = [analyzer.analyze(r, source_config("mjc_kakao")) for r in raws]
    sources = analyzer.decided_by
    assert sources["gemma"] >= 1 and "model_gemma_failed" not in sources  # 두 합성 공고 모두 꼬리표 확률이 문턱 근처
    for f in fields:
        assert "_analysis_version" not in f  # 정상 경로는 분석기 버전 그대로
    assert sum(f["category"] == "global" and f["interest_tags"] == ["global_language"] for f in fields) == sources["gemma"]
