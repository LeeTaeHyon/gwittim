from datetime import date

import pytest

from backend.analysis.dates import Point, date_info, parse_line, points_near


@pytest.mark.parametrize(
    ("line", "start", "end"),
    [
        ("신청기간: 2026.10.20.(화) ~ 2026.11.02.(월)", Point(date(2026, 10, 20), None), Point(date(2026, 11, 2), None)),
        ("• 예선(서류심사) : 2026.11.03.(화) ~ 11.05.(목), 서면평가", Point(date(2026, 11, 3), None), Point(date(2026, 11, 5), None)),
        ("• 본선(대면발표) : 2026.11.13.(금) 15:00 ~ 17:00, 본관", Point(date(2026, 11, 13), "15:00"), Point(date(2026, 11, 13), "17:00")),
        ("채용공고 ~ 2026. 10.18.(일) 10:00 까지", Point(date(2026, 10, 18), "10:00"), None),
        ("접수: 2026년 10월 20일 ~ 2026년 10월 31일", Point(date(2026, 10, 20), None), Point(date(2026, 10, 31), None)),
        ("1. 공모기간 : 2026.9.23.(수)~10.31.(토) 23시 59분까지", Point(date(2026, 9, 23), None), Point(date(2026, 10, 31), "23:59")),
        ("원서접수 2026.10.26.(월) 10시 ~ 2026.10.30.(금) 17시", Point(date(2026, 10, 26), "10:00"), Point(date(2026, 10, 30), "17:00")),
        ("모집기간 2026-12-30 ~ 01-05", Point(date(2026, 12, 30), None), Point(date(2027, 1, 5), None)),
        ("접수마감일 / 26.12.30(수)", Point(date(2026, 12, 30), None), None),  # 두 자리 연도 (D-014)
        ("26.10.21.(수) ~ 26.11.03.(화)", Point(date(2026, 10, 21), None), Point(date(2026, 11, 3), None)),
    ],
)
def test_parse_line(line, start, end):
    assert parse_line(line) == (start, end)


@pytest.mark.parametrize(
    "line",
    [
        "직전 학기 평점 3.0 이상",  # 연도 없는 숫자는 날짜로 보지 않음
        "2~3학년 재학생",
        "2026.13.40 잘못된 날짜",
        "접수마감일 26.12.30(목)",  # 두 자리 연도인데 요일이 달력과 다름
        "버전 26.12.30 배포",  # 두 자리 연도는 요일이 있어야 함
    ],
)
def test_not_a_date(line):
    assert parse_line(line) == (None, None)


def test_date_only_has_no_time_or_timezone():
    info = date_info(Point(date(2026, 11, 2), None), "~ 2026.11.02.(월)", "Asia/Seoul")
    assert info == {"date": "2026-11-02", "time": None, "timezone": None, "precision": "date", "evidence": "~ 2026.11.02.(월)"}


def test_minute_precision_uses_source_timezone():
    info = date_info(Point(date(2026, 10, 18), "10:00"), "10:00 까지", "Asia/Seoul")
    assert (info["precision"], info["timezone"]) == ("minute", "Asia/Seoul")


# ---------- 연도 없는 날짜 (알림톡, D-016) ----------

@pytest.mark.parametrize(
    ("line", "anchor", "expected"),
    [
        ("모집: 9월 11일(금)까지 선착순", date(2026, 9, 9), [Point(date(2026, 9, 11), None)]),
        ("내일 ★★10/7(수) 17:00까지★★", date(2026, 10, 6), [Point(date(2026, 10, 7), "17:00")]),
        ("12/14까지 E-Class에 제출", date(2026, 9, 21), [Point(date(2026, 12, 14), None)]),
        ("10월 16일 15시부터 체육관에서 진행", date(2026, 10, 14), [Point(date(2026, 10, 16), "15:00")]),
        ("1월 5일(화)까지", date(2026, 12, 10), [Point(date(2027, 1, 5), None)]),  # 연말 발송: 다음 해
        ("기간: 2026.9.1.(화) ~ 9.11.(금)", date(2026, 8, 31), [Point(date(2026, 9, 1), None), Point(date(2026, 9, 11), None)]),
        ("9월 12일(금)까지", date(2026, 9, 9), []),  # 요일이 달력과 다르면 버린다
        ("오늘(10/28) 신청 마감", date(2026, 10, 28), []),  # 빗금 날짜는 요일·'까지'·시각이 붙을 때만
        ("평점 3.5 이상, 1/2 이상 출석", date(2026, 10, 1), []),
        ("3월 2일 개강", date(2026, 7, 1), []),  # 발송일 앞 60일 ~ 뒤 240일 밖이면 연도를 정하지 않는다
    ],
)
def test_points_near(line, anchor, expected):
    assert points_near(line, anchor) == expected
