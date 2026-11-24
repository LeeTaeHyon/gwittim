"""기존 공고 본문 올리기 도구의 건조 실행 분류."""
import json

from tools.upload_notice_bodies import NOT_PUBLISHED, NO_RECORD, ROSTER_TITLE, TOO_SHORT, classify, main

BODY = "일시: 12월 3일 14시. 장소: 본관 301호. 제출물: 신청서 1부."


def _notice(title="공고", status="published"):
    return {"notice_id": "n", "title": title, "publication_status": status, "notice_version": 1}


def _record(body):
    return {"raw": {"body_text": body}}


def test_classify_reasons():
    notices = {
        "ok": _notice(), "pending": _notice(status="review_pending"), "roster": _notice("장학생 합격자 안내"),
        "short": _notice(), "nobody": _notice(), "norecord": _notice(),
    }
    records = {"ok": _record(BODY), "pending": _record(BODY), "roster": _record(BODY), "short": _record("짧음"), "nobody": _record(None)}
    upload, skipped = classify(notices, records)
    assert upload == {"ok": BODY}
    assert skipped == {"pending": NOT_PUBLISHED, "roster": ROSTER_TITLE, "short": TOO_SHORT, "nobody": TOO_SHORT, "norecord": NO_RECORD}


def test_dry_run_prints_counts_and_writes_nothing(tmp_path, capsys, monkeypatch):
    (tmp_path / "pipeline").mkdir()
    (tmp_path / "pipeline" / "records.json").write_text(json.dumps({"a": _record(BODY), "b": _record("x")}), encoding="utf-8")
    (tmp_path / "notices.json").write_text(json.dumps({"a": _notice(), "b": _notice()}), encoding="utf-8")
    monkeypatch.delenv("GWITTIM_FIREBASE_PROJECT_ID", raising=False)
    assert main(["--data", str(tmp_path)]) == 0
    out = capsys.readouterr().out
    assert "올릴 공고: 1건" in out and "빠지는 공고: 1건" in out and TOO_SHORT in out
    assert BODY not in out
