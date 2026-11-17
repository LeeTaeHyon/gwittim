"""알림톡 수집(D-019)을 합성 카톡 내보내기 파일로 검증한다. 실제 대화는 쓰지 않는다."""
from datetime import date

import pytest

from backend.analysis.kakao import KakaoAnalyzer
from backend.analysis.kakao_match import apply_url
from backend.batch import run_kakao
from backend.classifier import cascade
from backend.classifier.text_model import TextModel
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


def force_unsure(monkeypatch):
    """모든 공지를 '기타'(배운 꼬리표 밖)로 보게 해 Gemma 경로를 확실히 탄다. 테스트가 끝나면 되돌아간다."""
    monkeypatch.setattr(TextModel.load(cascade.INTEREST_MODEL), "other_threshold", 0.0)


def test_run_kakao_publishes_with_model_tags_and_gemma_fallback(tmp_path, monkeypatch):
    raws = to_raw_notices(export_dir(tmp_path), collected_at="2026-10-30T01:00:00Z")
    model_tags = {r["title"]: cascade.classify(r["title"], r["body_text"]).interest_ids for r in raws}
    force_unsure(monkeypatch)
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
    assert ai["application_deadline"]["date"] == "2026-11-13" and ai["lifecycle_status"] == "open"
    # 애매해서 Gemma를 불렀지만 실패한 공고는 내 모델 결과로 게시하고, 다음 배치 때 다시 분석되도록 버전을 다르게 남긴다
    assert len(calls) == 2 and analyzer.decided_by["model_gemma_failed"] == 2
    for n in sink.public.values():
        assert n["analysis_version"].endswith("-nogemma")
        if n["category"] != "admin_notice":
            assert n["interest_tags"] == model_tags[n["title"]]

    # 같은 내보내기를 다시 넣으면 수정본으로 보지 않는다
    again = run_kakao(raws, store=store, sink=sink, notices=notices, today=date(2026, 10, 30), analyzer=KakaoAnalyzer())
    assert again.outcomes["unchanged"] == 2


def test_gemma_answer_replaces_interest_when_unsure(tmp_path, monkeypatch):
    raws = to_raw_notices(export_dir(tmp_path), collected_at="2026-10-30T01:00:00Z")
    alone = [KakaoAnalyzer().analyze(r, source_config("mjc_kakao")) for r in raws]
    force_unsure(monkeypatch)
    gemma = lambda title, text: {"interest_ids": ["global_language"], "category": "global", "for_all_students": False, "reason": ""}
    analyzer = KakaoAnalyzer(gemma=gemma)
    fields = [analyzer.analyze(r, source_config("mjc_kakao")) for r in raws]
    sources = analyzer.decided_by
    assert sources["gemma"] == 2 and "model_gemma_failed" not in sources
    for f in fields:
        assert "_analysis_version" not in f  # 정상 경로는 분석기 버전 그대로
    # Gemma는 관심사만 바꾸고 종류는 내 모델 답 그대로 (D-035). 행정 공지는 꼬리표 없이 게시
    for f, a in zip(fields, alone):
        assert f["category"] == a["category"]
        assert f["interest_tags"] == ([] if f["category"] == "admin_notice" else ["global_language"])


# ---------- 연도 없는 날짜, 지난 공고, 제목 (D-019) ----------

DATED = (
    HEADER
    + day("2026년 9월 9일 수요일")
    + msg("오전 9:00", "[합성 샘플] 어학 아카데미 안내\n모집: 9월 11일(금)까지 선착순")
    + day("2026년 10월 14일 수요일")
    + msg("오전 9:00", "명지전문대학 합성센터입니다.\n[합성 샘플] 운동 특강 안내\n10월 16일 15시 체육관에서 진행")
    + day("2026년 10월 21일 수요일")
    + msg("오전 9:00", "[합성 샘플] 카드뉴스 공모전\n특강: 10월 29일 진행\n제출: 11/20(금)까지")
)


def by_title(notices: dict, word: str) -> dict:
    return next(n for n in notices.values() if word in n["title"])


def test_yearless_dates_fill_deadline_and_activity(tmp_path):
    raws = to_raw_notices(export_dir(tmp_path, DATED))
    notices = {}
    run_kakao(raws, store=InMemoryStore(), sink=InMemorySink(), notices=notices, today=date(2026, 10, 30), analyzer=KakaoAnalyzer())
    for n in notices.values():
        assert schema_errors("notice", n) == [] and n["publication_status"] == "published"

    academy = by_title(notices, "어학")
    assert academy["application_deadline"]["date"] == "2026-09-11" and academy["lifecycle_status"] == "closed"
    # 마감 없이 특강 날짜만 있는 안내: 활동일이 지나면 끝난 공고
    lecture = by_title(notices, "운동 특강")
    assert lecture["application_deadline"] is None
    assert lecture["activity_period"]["start"] == {
        "date": "2026-10-16", "time": "15:00", "timezone": "Asia/Seoul", "precision": "minute", "evidence": "10월 16일 15시 체육관에서 진행",
    }
    assert lecture["lifecycle_status"] == "closed"
    contest = by_title(notices, "카드뉴스")
    assert contest["application_deadline"]["date"] == "2026-11-20" and contest["lifecycle_status"] == "open"
    assert contest["activity_period"]["start"]["date"] == "2026-10-29"


def test_greeting_line_is_not_title(tmp_path):
    raws = to_raw_notices(export_dir(tmp_path, DATED))
    assert "[합성 샘플] 운동 특강 안내" in [r["title"] for r in raws]


def test_past_kakao_notices_are_not_published_until_then_closed(tmp_path):
    raws = to_raw_notices(export_dir(tmp_path, DATED))
    store, sink, notices = InMemoryStore(), InMemorySink(), {}
    report = run_kakao(raws, store=store, sink=sink, notices=notices, today=date(2026, 10, 30), analyzer=KakaoAnalyzer())
    assert report.held_past == 2 and report.published == 1
    assert [n["title"] for n in sink.public.values()] == ["[합성 샘플] 카드뉴스 공모전"]

    # 게시한 공고는 마감이 지나도 closed 상태로 갱신해 게시한다. 처음부터 지난 공고는 계속 올리지 않는다
    later = run_kakao(raws, store=store, sink=sink, notices=notices, today=date(2026, 11, 21), analyzer=KakaoAnalyzer())
    assert later.held_past == 2
    assert [n["lifecycle_status"] for n in sink.public.values()] == ["closed"]

    # 이미 게시한 끝난 공고는 분석이 바뀌면(예: 모델 교체) 공개본도 맞춘다. 나머지 지난 공고는 여전히 올리지 않는다
    (public_id,) = sink.public
    sink.public[public_id] = dict(sink.public[public_id], analysis_version="old", category="academic")
    again = run_kakao(raws, store=store, sink=sink, notices=notices, today=date(2026, 11, 22), analyzer=KakaoAnalyzer())
    assert again.held_past == 2 and again.published == 1
    assert sink.public[public_id]["analysis_version"] == notices[next(iter(k for k, v in notices.items() if v["notice_id"] == public_id))]["analysis_version"]
    assert len(sink.public) == 1
    quiet = run_kakao(raws, store=store, sink=sink, notices=notices, today=date(2026, 11, 22), analyzer=KakaoAnalyzer())
    assert quiet.published == 0 and quiet.skipped == 1  # 같으면 다시 쓰지 않는다


# ---------- 게시판 공고와 짝, 신청 사이트 (D-025) ----------

def board(notice_id: str, title: str, published: str = "2026-10-21") -> dict:
    return {
        "notice_id": notice_id, "source_id": "mjc_www_notice", "title": title, "lifecycle_status": "open",
        "published": {"date": published, "time": None, "timezone": None, "precision": "date", "evidence": published},
    }


def kakao(notices: dict, word: str) -> dict:
    return next(n for n in notices.values() if n["source_id"] == "mjc_kakao" and word in n["title"])


BOARD = {
    "w1": board("n_crew1", "[혁신] 2026학년도 2학기 Learning C.R.E.W(대면 특강) 실시 안내(1회차_나의강점 발견)"),
    "w2": board("n_crew2", "[혁신] 2026학년도 2학기 Learning C.R.E.W(대면 특강) 실시 안내(2회차_엑셀활용 with AI)"),
    "w3": board("n_contest", "[혁신] 2026학년도 2학기 AI Study+ ★AI 활용 경진대회 참가 안내★"),
    "w4": board("n_workshop", "[혁신] 2026학년도 2학기 AI Study+ 대면 워크숍 실시 안내"),
    "w5": board("n_old", "[혁신] 2026학년도 2학기 AI Study+ 대면 워크숍 실시 안내", published="2026-08-01"),  # 날짜 창 밖
    "w6": board("n_skill", "[혁신] 2026학년도 글로벌 스킬업 동아리 실시 안내"),
}
LINKED = (
    HEADER
    + day("2026년 10월 21일 수요일")
    + msg("오전 9:00", "[합성 샘플] <나의 강점 발견부터 AI 활용 엑셀까지! Learning C.R.E.W 대면특강 안내>\n"
          "1회차 나의 강점 발견 / 2회차 엑셀 활용\n신청: 스마트케어시스템(mpu.mjc.ac.kr)\n신청: 11월 20일(금)까지")
    + msg("오전 10:00", "[합성 샘플] 중간고사 이후, 학습 노하우를 AI 카드뉴스로 만들어 보세요!\n"
          "1. AI Study+ 대면 워크숍\n2. (AI Study+) AI 활용 경진대회 - 공모전\n신청: 11.20.(금)까지 (https://mpu.mjc.ac.kr)")
    + msg("오전 11:00", "[합성 샘플] 글로벌 스킬업 동아리 교재 배부 안내\n배부: 11월 20일(금)까지")
)


def test_kakao_same_as_board_notice_is_not_published(tmp_path):
    raws = to_raw_notices(export_dir(tmp_path, LINKED))
    store, sink, notices = InMemoryStore(), InMemorySink(), dict(BOARD)
    report = run_kakao(raws, store=store, sink=sink, notices=notices, today=date(2026, 10, 30), analyzer=KakaoAnalyzer())
    assert report.duplicates == 1 and report.published == 2
    crew = kakao(notices, "C.R.E.W")
    assert crew["notice_id"] not in sink.public
    assert {r["notice_id"] for r in crew["related_notices"]} == {"n_crew1", "n_crew2"}

    # 여러 프로그램 묶음은 게시하고 관련 학교 공지를 붙인다. 알림톡에만 있는 말('카드뉴스')이 제목에 남아 있다
    card = sink.public[kakao(notices, "카드뉴스")["notice_id"]]
    assert [r["notice_id"] for r in card["related_notices"]] == ["n_contest", "n_workshop"]
    assert card["apply_url"] == "https://mpu.mjc.ac.kr"
    # '교재 배부'는 '동아리 실시 안내'와 다른 공지: 관련으로만 붙고 게시된다
    books = sink.public[kakao(notices, "교재 배부")["notice_id"]]
    assert [r["notice_id"] for r in books["related_notices"]] == ["n_skill"] and books["apply_url"] is None
    for n in sink.public.values():
        assert schema_errors("notice", n) == []


def test_crew_kakao_published_earlier_is_taken_down(tmp_path):
    raws = to_raw_notices(export_dir(tmp_path, LINKED))
    store, sink, notices = InMemoryStore(), InMemorySink(), {}
    run_kakao(raws, store=store, sink=sink, notices=notices, today=date(2026, 10, 30), analyzer=KakaoAnalyzer())
    crew_id = kakao(notices, "C.R.E.W")["notice_id"]
    assert crew_id in sink.public  # 게시판 공고를 아직 모를 때는 게시

    notices.update(BOARD)  # 게시판 배치 뒤 다시 실행
    report = run_kakao(raws, store=store, sink=sink, notices=notices, today=date(2026, 10, 30), analyzer=KakaoAnalyzer())
    assert report.duplicates == 1 and crew_id not in sink.public
    # 원문·분석이 그대로여도 관련 학교 공지가 생기면 다시 게시한다
    assert sink.public[kakao(notices, "카드뉴스")["notice_id"]]["related_notices"]


@pytest.mark.parametrize(
    ("body", "url"),
    [
        ("- 신청방법 : 스마트케어 시스템(mpu.mjc.ac.kr)에서 신청", "https://mpu.mjc.ac.kr"),
        ("자세한 내용은 교수학습센터(https://ctl.mjc.ac.kr/ctl/main/main_form.acl) 참고", "https://ctl.mjc.ac.kr/ctl/main/main_form.acl"),
        ("Zoom 회의 참가 https://us06web.zoom.us/j/1234", None),  # 학교 사이트가 아니면 붙이지 않는다
        ("문의는 교수학습센터로", None),
    ],
)
def test_apply_url_is_first_school_site(body, url):
    assert apply_url(body) == url


# ---------- 폰 수집기 받은편지함과 PC 내보내기 합치기 (D-036) ----------

AI_TEXT = "[합성 샘플] 2026 교내 AI 데이터 분석 경진대회 참가팀 모집\n대상: 재학생\n신청기간: 2026.10.20.(화) ~ 2026.11.13.(금)"


def phone_doc(text=AI_TEXT, sent_at="2026-10-20T14:05:00+09:00"):
    from backend.collectors.mjc_kakao.inbox import accept

    accepted = accept({"room": ROOM, "sent_at": sent_at, "text": text}, "2026-10-20T05:06:00Z")
    assert accepted is not None
    return accepted[1]


def test_phone_only_notice_becomes_raw_notice():
    (raw,) = to_raw_notices([], collected_at="2026-10-20T06:00:00Z", inbox=[phone_doc()])
    assert raw["title"] == "[합성 샘플] 2026 교내 AI 데이터 분석 경진대회 참가팀 모집"
    assert raw["published"]["date"] == "2026-10-20" and raw["published"]["time"] == "14:05"
    assert schema_errors("raw_notice", raw) == []


def test_phone_id_stays_when_export_arrives(tmp_path):
    (alone,) = to_raw_notices([], collected_at="2026-10-20T06:00:00Z", inbox=[phone_doc()])
    raws = to_raw_notices(export_dir(tmp_path), collected_at="2026-10-30T01:00:00Z", inbox=[phone_doc()])
    assert len(raws) == 2  # 폰 알림과 내보내기의 같은 공지는 한 공고
    ai = next(r for r in raws if "AI" in r["title"])
    assert ai["source_notice_id"] == alone["source_notice_id"]


def test_truncated_phone_text_joins_export_and_takes_export_body(tmp_path):
    cut = AI_TEXT[:45]  # 알림에 앞부분만 온 경우
    (alone,) = to_raw_notices([], collected_at="2026-10-20T06:00:00Z", inbox=[phone_doc(cut, "2026-10-20T14:06:00+09:00")])
    raws = to_raw_notices(export_dir(tmp_path), collected_at="2026-10-30T01:00:00Z",
                          inbox=[phone_doc(cut, "2026-10-20T14:06:00+09:00")])
    assert len(raws) == 2
    ai = next(r for r in raws if "AI" in r["title"])
    assert ai["source_notice_id"] == alone["source_notice_id"]  # 폰이 먼저 받은 ID 그대로
    assert "2026.11.13." in ai["body_text"]  # 본문은 온전한 내보내기 글


def test_phone_resend_of_published_notice_keeps_export_id(tmp_path):
    # 내보내기에 10/20 첫 발송과 10/22 재발송이 있다. 폰이 10/22 재발송을 받아도 이미 게시한 공고 ID 그대로
    exported = next(r for r in to_raw_notices(export_dir(tmp_path), collected_at="x") if "AI" in r["title"])
    raws = to_raw_notices(export_dir(tmp_path), collected_at="x", inbox=[phone_doc(sent_at="2026-10-22T09:00:00+09:00")])
    assert len(raws) == 2
    ai = next(r for r in raws if "AI" in r["title"])
    assert ai["source_notice_id"] == exported["source_notice_id"]


def test_export_only_raws_unchanged_by_empty_inbox(tmp_path):
    assert to_raw_notices(export_dir(tmp_path), collected_at="x") == to_raw_notices(export_dir(tmp_path), collected_at="x", inbox=[])



def test_phone_preview_flag_only_for_phone_only_group(tmp_path):
    (alone,) = to_raw_notices([], collected_at="2026-10-20T06:00:00Z", inbox=[phone_doc()])
    assert alone["source_fields"]["phone_preview"] is True
    assert schema_errors("raw_notice", alone) == []
    # 내보내기와 합쳐지면 키 자체가 없다 (내보내기만 있을 때와 content_hash도 같다)
    cut = AI_TEXT[:45]
    joined = to_raw_notices(export_dir(tmp_path), collected_at="x", inbox=[phone_doc(cut, "2026-10-20T14:06:00+09:00")])
    assert all("phone_preview" not in r["source_fields"] for r in joined)
    only_export = to_raw_notices(export_dir(tmp_path), collected_at="x")
    # 내보내기만 있던 다른 공고의 content_hash는 그대로다
    rest = lambda raws: {r["content_hash"] for r in raws if "AI" not in r["title"]}
    assert rest(joined) == rest(only_export)


def test_phone_preview_becomes_body_preview_on_notice():
    (raw,) = to_raw_notices([], collected_at="2026-10-20T06:00:00Z", inbox=[phone_doc()])
    notices = {}
    run_kakao([raw], store=InMemoryStore(), sink=InMemorySink(), notices=notices, today=date(2026, 10, 21), analyzer=KakaoAnalyzer())
    (notice,) = notices.values()
    assert notice["body_preview"] is True and schema_errors("notice", notice) == []


def test_exported_notice_has_no_body_preview(tmp_path):
    notices = {}
    run_kakao(to_raw_notices(export_dir(tmp_path)), store=InMemoryStore(), sink=InMemorySink(), notices=notices,
              today=date(2026, 10, 30), analyzer=KakaoAnalyzer())
    assert notices and all("body_preview" not in n for n in notices.values())


def test_latest_exports_picks_newest_file_per_room(tmp_path):
    from backend.collectors.mjc_kakao.__main__ import latest_exports

    base, auto = tmp_path / "base", tmp_path / "auto"
    base.mkdir()
    auto.mkdir()
    names = {
        base: ["KakaoTalk_20261029_1935_53_981_명지전문대학 공지사항.txt", "KakaoTalk_20261029_1936_49_009_명지전문대학 상담센터.txt"],
        auto: ["KakaoTalk_20261118_0543_00_909_명지전문대학 공지사항.txt", "KakaoTalk_20261117_0900_00_000_명지전문대학 공지사항.txt"],
    }
    for d, files in names.items():
        for f in files:
            (d / f).write_text("x", encoding="utf-8")
    got = [p.replace("\\", "/").rsplit("/", 2)[-2:] for p in latest_exports([base, auto])]
    assert sorted(got) == [
        ["auto", "KakaoTalk_20261118_0543_00_909_명지전문대학 공지사항.txt"],
        ["base", "KakaoTalk_20261029_1936_49_009_명지전문대학 상담센터.txt"],  # 자동 내보내기에 없는 방은 기준 파일
    ]
    assert latest_exports([base]) == sorted(str(base / f) for f in names[base])
