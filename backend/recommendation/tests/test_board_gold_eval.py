"""게시판 정답표 도구(표 만들기 -> 일치 -> 채점) 검사. 합성 공고만 쓴다."""
from __future__ import annotations

import json

import pytest

from tools import board_gold_agreement, eval_board_extraction, make_board_gold_sheet
from tools.board_gold_common import COLUMNS, read_sheet, write_sheet

SOURCES = ["mjc_www_notice", "mjc_www_job", "mjc_www_scholarship", "mjc_www_work"]
EMPTY_EL = {"conditions": [], "unresolved_conditions": [], "extraction_complete": False,
            "explicitly_unrestricted": False, "unrestricted_evidence": None}


def _notice(nid, source, eligibility=None, deadline=None):
    return {
        "notice_id": nid, "source_id": source, "source_url": f"https://example.invalid/{nid}",
        "title": f"합성 제목 {nid}", "summary": "합성 요약 문장은 표에 들어가면 안 됨",
        "application_deadline": deadline, "eligibility": eligibility or EMPTY_EL,
    }


def _date(d):
    return {"date": d, "time": None, "timezone": None, "precision": "date", "evidence": "합성 근거"}


def _cond(field, value, evidence, status="validated"):
    return {"field": field, "operator": "eq", "value": value, "evidence": evidence, "validation_status": status}


@pytest.fixture
def notices():
    items = [
        # 정답: 자유조건 있음(needs_check)인데 분석은 제한 없음 -> 틀린 지원 가능
        _notice("mjc_www_notice:1", SOURCES[0], {**EMPTY_EL, "extraction_complete": True, "explicitly_unrestricted": True,
                                                  "unrestricted_evidence": "합성 누구나 지원"}, _date("2030-01-10")),
        # 정답: 재학생만(휴학 프로필은 not_met), 분석도 같음. 마감일 틀림
        _notice("mjc_www_notice:2", SOURCES[0], {**EMPTY_EL, "extraction_complete": True,
                                                  "conditions": [_cond("enrollment_status", "enrolled", "합성 재학생 대상")]},
                _date("2030-02-01")),
        # 정답: 누구나, 분석 제한 없음 -> met, met
        _notice("mjc_www_job:1", SOURCES[1], {**EMPTY_EL, "extraction_complete": True, "explicitly_unrestricted": True,
                                               "unrestricted_evidence": "합성 제한 없음"}, _date("2030-03-03")),
        # 정답: 자유조건 있고 분석이 미해석으로 잡음
        _notice("mjc_www_job:2", SOURCES[1], {**EMPTY_EL, "unresolved_conditions": [
            {"evidence": "합성 토익 700점 이상 지원 가능", "note": None}]}),
        _notice("mjc_www_scholarship:1", SOURCES[2]),
        _notice("mjc_www_work:1", SOURCES[3]),
        _notice("mjc_kakao:1", "mjc_kakao"),
    ]
    return {n["notice_id"]: n for n in items}


def _fill(path, answers):
    rows = read_sheet(path)
    for r in rows:
        r.update(answers[r["notice_id"]])
    write_sheet(path, rows)


BASE = {"학교": "없음", "학과": "없음", "학년": "없음", "재학상태": "없음", "자유조건": "", "누구나": "Y", "메모": ""}
ANSWERS = {
    "mjc_www_notice:1": {**BASE, "마감일": "2030-01-10", "자유조건": "합성 평점 3.0 이상 학생\n합성 소득 분위 제한"},
    "mjc_www_notice:2": {**BASE, "마감일": "2030-02-15", "재학상태": "enrolled", "누구나": "N"},
    "mjc_www_job:1": {**BASE, "마감일": "2030-03-03"},
    "mjc_www_job:2": {**BASE, "마감일": "없음", "누구나": "N", "자유조건": "합성 토익 700점 이상"},
    "mjc_www_scholarship:1": {**BASE, "마감일": "판단불가"},
    "mjc_www_work:1": {**BASE, "마감일": "없음"},
}


def test_sheet_has_no_analysis_and_refuses_overwrite(tmp_path, notices):
    src = tmp_path / "notices.json"
    src.write_text(json.dumps(notices, ensure_ascii=False), encoding="utf-8")
    out = tmp_path / "gold"
    assert make_board_gold_sheet.main(["--notices", str(src), "--out-dir", str(out)]) == 0

    a, b = read_sheet(out / "board_sheet_A.csv"), read_sheet(out / "board_sheet_B.csv")
    assert list(a[0].keys()) == COLUMNS
    assert len(a) == len(b) == 6  # 게시판 공고만, 카카오 제외
    assert {r["notice_id"] for r in a} == {r["notice_id"] for r in b}
    for r in a:
        assert all(r[c] == "" for c in COLUMNS[4:])
    text = (out / "board_sheet_A.csv").read_text(encoding="utf-8-sig")
    assert "합성 요약" not in text and "2030-" not in text
    assert "mjc.computer_engineering" in (out / "board_guide.txt").read_text(encoding="utf-8")

    before = (out / "board_sheet_A.csv").read_bytes()
    assert make_board_gold_sheet.main(["--notices", str(src), "--out-dir", str(out)]) == 1
    assert (out / "board_sheet_A.csv").read_bytes() == before


def test_full_flow_catches_wrong_met(tmp_path, notices, capsys):
    src = tmp_path / "notices.json"
    src.write_text(json.dumps(notices, ensure_ascii=False), encoding="utf-8")
    out = tmp_path / "gold"
    make_board_gold_sheet.main(["--notices", str(src), "--out-dir", str(out)])
    a_path, b_path = out / "board_sheet_A.csv", out / "board_sheet_B.csv"

    _fill(a_path, ANSWERS)
    b_answers = {k: dict(v) for k, v in ANSWERS.items()}
    b_answers["mjc_www_job:1"]["마감일"] = "2030-03-04"  # 마감일 갈림
    b_answers["mjc_www_work:1"]["누구나"] = "N"  # 누구나 갈림
    _fill(b_path, b_answers)

    args = ["--a", str(a_path), "--b", str(b_path), "--out-dir", str(out)]
    assert board_gold_agreement.main(args) == 0
    rate = capsys.readouterr().out
    assert "마감일 일치: 5/6" in rate and "누구나 일치: 5/6" in rate
    dis = out / "board_disagreements.csv"
    rows = list(__import__("csv").DictReader(dis.open(encoding="utf-8-sig", newline="")))
    assert {(r["notice_id"], r["항목"]) for r in rows} == {("mjc_www_job:1", "마감일"), ("mjc_www_work:1", "누구나")}

    # 합의 칸이 비어 있으면 합치기를 거부
    assert board_gold_agreement.main(args + ["--merge"]) == 1
    assert not (out / "board_gold.csv").exists()
    for r in rows:
        r["합의"] = "2030-03-03" if r["항목"] == "마감일" else "N"
    write_sheet(dis, rows, list(rows[0].keys()))
    capsys.readouterr()
    assert board_gold_agreement.main(args + ["--merge"]) == 0
    assert "SHA-256" in capsys.readouterr().out
    gold = {r["notice_id"]: r for r in read_sheet(out / "board_gold.csv")}
    assert gold["mjc_www_job:1"]["마감일"] == "2030-03-03"
    assert gold["mjc_www_work:1"]["누구나"] == "N"
    assert gold["mjc_www_notice:1"]["자유조건"] == ANSWERS["mjc_www_notice:1"]["자유조건"]  # A 값

    res = eval_board_extraction.evaluate_all(read_sheet(out / "board_gold.csv"), notices)
    wm = res["판정"]["틀린_지원_가능"]
    assert res["판정"]["틀린_지원_가능_건수"] == len(wm) > 0
    assert {w["notice_id"] for w in wm} >= {"mjc_www_notice:1"}
    assert all(w["정답"] != "met" for w in wm)
    # 정답 met인 공고(job:1)는 틀린 지원 가능에 들지 않는다
    assert "mjc_www_job:1" not in {w["notice_id"] for w in wm}

    d = res["마감일"]
    assert d["일치"] == 2 and d["분석이_낸_날짜"] == 3 and d["정답_날짜"] == 3  # 판단불가 행은 계산에서 빠짐
    assert [w["notice_id"] for w in d["틀린_날짜"]] == ["mjc_www_notice:2"]
    fr = res["자유_조건"]
    assert fr["정답_문구"] == 3 and fr["포착"] == 1  # 토익 문구만 잡힘
    assert {m["문구"] for m in fr["놓친_문구"]} == {"합성 평점 3.0 이상 학생", "합성 소득 분위 제한"}
    assert res["구조_조건"]["재학상태"]["tp"] == 1

    capsys.readouterr()
    assert eval_board_extraction.main(["--gold", str(out / "board_gold.csv"), "--notices", str(src)]) == 0
    assert capsys.readouterr().out.startswith("틀린 지원 가능: ")
    assert eval_board_extraction.main(["--gold", str(out / "board_gold.csv"), "--notices", str(src), "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["판정"]["틀린_지원_가능_건수"] == len(wm)


def test_free_condition_matching_is_not_too_loose():
    caught = eval_board_extraction.caught
    assert caught("토익 700점", ["합성 토익700점 이상"])[0]  # 공백·문장부호 무시
    assert not caught("토익", ["토익 700점 이상 지원"])[0]  # 짧은 문구는 잡은 것으로 세지 않음
    assert not caught("", ["아무 글"])[0]
    assert not caught("평점 3.0 이상", ["평점 3.0 이상" + " 다른 조건 문장" * 20])[0]  # 너무 긴 근거


def test_validation_reports_row_numbers(tmp_path, notices):
    src = tmp_path / "notices.json"
    src.write_text(json.dumps(notices, ensure_ascii=False), encoding="utf-8")
    out = tmp_path / "gold"
    make_board_gold_sheet.main(["--notices", str(src), "--out-dir", str(out)])
    a, b = out / "board_sheet_A.csv", out / "board_sheet_B.csv"
    _fill(a, ANSWERS)
    bad = {k: dict(v) for k, v in ANSWERS.items()}
    bad["mjc_www_job:1"]["학과"] = "mjc.no_such_major"
    _fill(b, bad)
    with pytest.raises(SystemExit):
        board_gold_agreement.main(["--a", str(a), "--b", str(b), "--out-dir", str(out)])
