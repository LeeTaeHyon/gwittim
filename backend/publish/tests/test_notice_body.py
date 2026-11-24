"""공고 본문 서버 전용 저장 (docs/agent-detail-body-spec.md §4.1)."""
import json
from pathlib import Path

from backend.publish import InMemorySink, publish
from backend.publish.publisher import body_for_storage

ROOT = Path(__file__).resolve().parents[3]
BODY = "일시: 12월 3일 14시. 장소: 본관 301호. 제출물: 신청서 1부."


def notice(**fields) -> dict:
    n = json.loads((ROOT / "fixtures/valid/notice/date_only_timezone_unknown.json").read_text(encoding="utf-8"))
    n.update(fields)
    return n


class CountingSink(InMemorySink):
    def __init__(self):
        super().__init__()
        self.body_writes = 0
        self.body_reads = 0

    def get_body(self, notice_id):
        self.body_reads += 1
        return super().get_body(notice_id)

    def put_body(self, doc):
        self.body_writes += 1
        super().put_body(doc)


def test_published_notice_stores_body():
    sink = InMemorySink()
    publish(notice(), [], sink, BODY)
    doc = sink.bodies["n_synthetic_0001"]
    assert doc["body_text"] == BODY and doc["notice_version"] == notice()["notice_version"]
    assert doc["notice_id"] == "n_synthetic_0001" and doc["updated_at"].endswith("Z")


def test_same_body_is_not_written_again():
    sink = CountingSink()
    publish(notice(), [], sink, BODY)
    publish(notice(), [], sink, BODY)  # 공개본도 같아 건너뛰는 경우
    publish(notice(notice_version=2), [], sink, BODY)  # 공개본은 새로 쓰지만 본문은 같음
    assert sink.body_writes == 1
    publish(notice(notice_version=3), [], sink, BODY + " 추가")
    assert sink.body_writes == 2


def test_skipped_publish_does_not_touch_body():
    """공고가 바뀌지 않아 건너뛰면 본문을 읽지도 쓰지도 않는다. 예전 공고의 본문은 올리기 도구가 채운다."""
    sink = CountingSink()
    publish(notice(), [], sink)  # 본문 없이 게시(예전 방식)
    assert not sink.bodies
    reads = sink.body_reads
    publish(notice(), [], sink, BODY)  # 공개본이 같아 건너뜀
    assert not sink.bodies and sink.body_reads == reads and sink.body_writes == 0


def test_unpublished_notice_does_not_store_body():
    sink = InMemorySink()
    publish(notice(publication_status="review_pending"), ["x"], sink, BODY)
    assert not sink.bodies and not sink.public
    publish(notice(), ["검증 실패"], sink, BODY)
    assert not sink.bodies


def test_taking_public_copy_down_removes_body():
    sink = InMemorySink()
    publish(notice(), [], sink, BODY)
    publish(notice(notice_version=2, publication_status="review_pending"), ["x"], sink, BODY)
    assert not sink.public and not sink.bodies
    publish(notice(), [], sink, BODY)
    sink.delete_public("n_synthetic_0001")  # 배치의 중복 공고 내리기 경로
    assert not sink.bodies


def test_roster_title_and_short_body_are_not_stored():
    for title in ("2026학년도 장학생 합격자 안내", "해외연수 선발 결과 발표", "공모전 수상자 공지", "최종 명단 공고"):
        assert body_for_storage(title, BODY) is None, title
    assert body_for_storage("제목", "x" * 19) is None
    assert body_for_storage("제목", " \n ") is None and body_for_storage("제목", None) is None
    assert body_for_storage("제목", "가" * 20) == "가" * 20
    sink = InMemorySink()
    publish(notice(title="장학생 합격자 안내"), [], sink, BODY)
    assert "n_synthetic_0001" in sink.public and not sink.bodies


def test_body_that_becomes_unusable_is_removed():
    sink = InMemorySink()
    publish(notice(), [], sink, BODY)
    publish(notice(notice_version=2), [], sink, "짧음")  # 바뀐 공고에서 본문이 쓸 수 없게 됨
    assert not sink.bodies
