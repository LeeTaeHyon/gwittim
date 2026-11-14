"""측정 앱 기록과 내보내기 본문 비교 도구 (tools/compare_notif_probe.py). 합성 기록만 쓴다."""
import json

from tools import compare_notif_probe as cmp

ROOM = "명지전문대학 글로벌교육센터"
FULL = (
    "글로벌교육센터 겨울방학 영어 회화 어학 프로그램 안내\n"
    "원어민 1:1 수준별 외국어회화 프로그램을 온라인으로 신청하세요.\n"
    "모집기간: 12월 5일까지\n교육과목: 영어, 중국어, 일본어\nTOEIC 대비반도 함께 운영합니다."
)


def record(rid, key, body=None, *, big=None, idx=0, summary=False, room=ROOM, at="2026-11-20T10:00:05.000+09:00"):
    fields = {"title": {"value": room, "length": len(room)}, "text": None, "big_text": None}
    if body is not None:
        fields["text"] = {"value": body, "length": len(body)}
    if big is not None:
        fields["big_text"] = {"value": big, "length": len(big)}
    return {"id": rid, "key": key, "update_index": idx, "is_group_summary": summary, "room": room,
            "post_time": at, "fields": fields, "messages": []}


def write(path, rows):
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")


def notice(nid, text, at="2026-11-20T10:00:00+09:00", room=ROOM):
    return {"id": nid, "room": room, "sent_at": at, "title": text.split("\n")[0], "text": text}


def test_body_prefers_big_text_then_messages():
    r = record("a", "k", "짧은 본문", big="펼친 본문")
    assert cmp.body_of(r) == ("펼친 본문", "big_text")
    r = record("a", "k", "짧은 본문")
    r["messages"] = [{"text": "메시지 하나"}, {"text": "가장 긴 메시지 본문"}]
    assert cmp.body_of(r) == ("가장 긴 메시지 본문", "messages")
    assert cmp.body_of(record("a", "k")) is None


def test_updates_collapse_and_summary_dropped():
    rows = [record("a", "k1", FULL[:40]), record("b", "k1", FULL, idx=1), record("c", "k2", "요약", summary=True)]
    kept = cmp.latest_per_key(rows)
    assert [r["id"] for r in kept] == ["b"]


def test_pairs_by_room_time_and_text(tmp_path):
    probe = tmp_path / "probe"
    probe.mkdir()
    write(probe / "records.jsonl", [
        record("full", "k1", big=FULL),
        record("cut", "k2", FULL[:60], at="2026-11-20T10:00:09.000+09:00"),
        record("late", "k3", FULL, at="2026-11-21T10:00:00.000+09:00"),  # 하루 뒤: 시간 창 밖
        record("other", "k4", FULL, room="명지전문대학 상담센터"),  # 다른 방
    ])
    from tools.compare_notif_probe import judge
    dev = judge(FULL.split("\n")[0], FULL)
    write(probe / "classified.jsonl", [{"id": "full", "title": FULL.split("\n")[0], **dev}])
    notices = tmp_path / "notices.jsonl"
    write(notices, [notice("n1", FULL), notice("n2", "전혀 다른 장학금 신청 안내 본문입니다. 성적 기준과 제출 서류를 확인하세요.")])

    result = cmp.compare(probe, [notices, tmp_path / "missing.jsonl"])
    pairs = {p["id"]: p for p in result["pairs"]}
    assert set(pairs) == {"full", "cut"}
    assert all(p["notice_id"] == "n1" for p in pairs.values())
    assert pairs["full"]["truncated"] is False and pairs["cut"]["truncated"] is True
    assert pairs["full"]["interest_same"] and pairs["full"]["category_same"]
    assert {u["id"] for u in result["unmatched"]} == {"late", "other"}
    assert result["device_checked"] == 1 and result["device_same_as_server"] == 1
    assert result["length"]["count"] == 4 and result["length"]["under_short"] == 4  # 합성 본문은 200자 미만


def test_main_writes_summary_without_text(tmp_path, capsys):
    probe = tmp_path / "probe"
    probe.mkdir()
    write(probe / "records.jsonl", [record("full", "k1", big=FULL)])
    notices = tmp_path / "notices.jsonl"
    write(notices, [notice("n1", FULL)])
    assert cmp.main(["--probe-dir", str(probe), "--notices", str(notices)]) == 0
    out = (probe / "compare.json").read_text(encoding="utf-8")
    assert "원어민" not in out  # 원문은 남기지 않는다
    assert "관심사 판정 일치 1/1" in capsys.readouterr().out
    assert cmp.main(["--probe-dir", str(tmp_path / "none")]) == 1
