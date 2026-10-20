"""추천 가중치·구간 설정. 바꾸면 RANKING_VERSION을 올린다 (SPEC §6 추천 8)."""

RANKING_VERSION = "rank-0.2"  # 0.2: 행정 공지(admin_notice) 제외

# SPEC §6 추천 4: 관심사 40, 직무 35, 전공 15, 시기 10
WEIGHTS = {
    "interest": 40,
    "role": 35,
    "major": 15,
    "timing": 10,
}

# 개인화 요소. 이 중 하나도 평가할 수 없으면 개인화 점수를 만들지 않는다.
PERSONAL_FACTORS = ("interest", "role", "major")

# D-005 #8: 마감까지 남은 날짜(일) 상한 → 값. 마지막 구간은 상한 없음.
TIMING_BANDS = ((14, 1.0), (30, 0.6), (None, 0.3))

# 기본 추천에서 제외 (SPEC §6 추천 1)
EXCLUDED_LIFECYCLE = {"closed", "removed"}
EXCLUDED_PUBLICATION = {"review_pending"}
EXCLUDED_CATEGORIES = {"admin_notice"}  # 학생 대상이 아닌 행정 공지

MAX_LIMIT = 50
