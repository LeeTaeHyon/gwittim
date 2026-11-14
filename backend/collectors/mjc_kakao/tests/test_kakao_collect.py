"""새 알림톡 모으기(localModel/kakao_collect.py)를 합성 내보내기 파일로 검증한다. 실제 대화는 쓰지 않는다."""
import csv
import json
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "localModel"))

import kakao_collect  # noqa: E402

ROOM, ROOM2 = "명지전문대학 합성채널", "명지전문대학 새합성채널"
OLD = "[합성 샘플] 2026 교내 AI 데이터 분석 경진대회 참가팀 모집\n대상: 재학생\n신청기간: 2026.10.20.(화) ~ 2026.11.13.(금)"
NEW = ("[합성 샘플] 겨울방학 영어 회화 프로그램 참가자 모집\n대상: 재학생 누구나\n"
       "운영: 2026.12.28.(월) ~ 2027.01.22.(금) 매주 월수 오후\n장소: 본관 3층 어학실\n신청: 스마트케어에서 신청")
# NEW의 날짜·장소만 바꾼 2차 모집: 자동으로 묶이지 않을 만큼 다르지만 비슷하다
NEW_2ND = ("[합성 샘플] 겨울방학 영어 회화 프로그램 2차 참가자 모집\n대상: 재학생 누구나\n"
           "운영: 2027.01.11.(월) ~ 2027.02.05.(금) 매주 화목 오전\n장소: 본관 3층 어학실\n신청: 스마트케어에서 신청")
OTHER_ROOM = "[합성 샘플] 학생 만족도 설문조사 안내\n기간: 11월 30일까지"


def export(raw_dir, ts, room, days, sub=""):
    """days: [(날짜 문자열, [(시각, 본문)])]"""
    lines = [f"{room} 님과 카카오톡 대화", "저장한 날짜 : 2026-11-01 10:00:00"]
    for d, msgs in days:
        lines.append(f"--------------- {d} ---------------")
        lines += [f"[{room}] [{t}] {text}" for t, text in msgs]
    folder = raw_dir / sub if sub else raw_dir
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"KakaoTalk_{ts}_00_000_{room}.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


BASE_DAYS = [("2026년 10월 20일 화요일", [("오후 2:05", OLD)])]
INBOX_DAYS = BASE_DAYS + [
    ("2026년 11월 2일 월요일", [("오전 9:00", OLD + "\n마감이 다가왔습니다")]),  # 기준 공지 재발송
    ("2026년 11월 3일 화요일", [("오전 10:00", NEW), ("오후 1:00", NEW_2ND)]),
]


def collected(raw_dir, name):
    path = raw_dir / "collected" / name
    if name.endswith(".csv"):
        with open(path, encoding="utf-8-sig") as f:
            return list(csv.DictReader(f))
    return [json.loads(l) for l in path.read_text(encoding="utf-8").splitlines() if l.strip()]


def test_collect_new_arrivals(tmp_path, capsys):
    export(tmp_path, "20261029_1935", ROOM, BASE_DAYS)  # 학습용 기준 내보내기
    export(tmp_path, "20261104_1200", ROOM, INBOX_DAYS, "inbox")
    export(tmp_path, "20261104_1201", ROOM2, [("2026년 11월 4일 수요일", [("오전 9:00", OTHER_ROOM)])], "inbox")
    now = datetime(2026, 11, 5)

    r = kakao_collect.collect(str(tmp_path), now=now)
    titles = [a["title"] for a in collected(tmp_path, "new_arrivals.jsonl")]
    # 기준 공지와 그 재발송은 빠지고, 새 공지 3건 (2차 모집은 따로 묶임)
    assert len(titles) == 3 and not any("경진대회" in t for t in titles)
    assert r["added"] == 3
    assert any(f"처음 보는 방: {ROOM2}" in w for w in r["warnings"])
    review = collected(tmp_path, "dup_review.csv")
    assert len(review) == 1 and review[0]["판단"] == ""
    assert {review[0]["제목_새"], review[0]["제목_기존"]} == {t for t in titles if "영어 회화" in t}
    assert "애매한 쌍 1개" in capsys.readouterr().out

    # 같은 파일을 다시 넣어도, 다시 돌려도 결과가 같다
    export(tmp_path, "20261104_1200", ROOM, INBOX_DAYS, "inbox")
    assert kakao_collect.collect(str(tmp_path), now=now)["added"] == 0

    # '같음'으로 판단하면 나중에 온 2차 모집을 뺀다. 판단은 다시 돌려도 남는다
    review[0]["판단"] = "같음"
    with open(tmp_path / "collected" / "dup_review.csv", "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=kakao_collect.REVIEW_COLUMNS)
        w.writeheader()
        w.writerows(review)
    r = kakao_collect.collect(str(tmp_path), now=now)
    titles = [a["title"] for a in collected(tmp_path, "new_arrivals.jsonl")]
    assert r["arrivals"] == 2 and r["pending"] == 0 and not any("2차" in t for t in titles)
    assert collected(tmp_path, "dup_review.csv")[0]["판단"] == "같음"

    # 최신 내보내기에서 기록이 잘려도 대장에 들어온 공지는 남고, 오래 안 했으면 경고
    export(tmp_path, "20261120_1200", ROOM, [("2026년 11월 3일 화요일", [("오후 1:00", NEW_2ND)])], "inbox")
    r = kakao_collect.collect(str(tmp_path), now=datetime(2026, 12, 1))
    assert r["ledger"] == 3
    assert any("최신 내보내기에 없음" in w for w in r["warnings"])
    assert any("마지막 내보내기가 10일 전" in w for w in r["warnings"])
    # 본문은 가린 글만 저장한다
    assert all("text" in a for a in collected(tmp_path, "ledger.jsonl"))
