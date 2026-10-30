"""추천 가중치·구간 설정. 바꾸면 RANKING_VERSION을 올린다 (SPEC §6 추천 8)."""

RANKING_VERSION = "rank-0.4"  # 0.4: 학과 통계 보조 점수(D-017). 0.3: 오래된 마감 미상 공고 제외(D-013). 0.2: 행정 공지 제외

# SPEC §6 추천 4: 관심사 40, 직무 35, 전공 15, 시기 10
# 학과 통계 20(D-017): 관심사·직무를 하나도 고르지 않은 학생에게만 평가한다. 직접 고른 관심사·직무보다 약하고
# 학과 꼬리표 일치(15)보다는 조금 세다.
WEIGHTS = {
    "interest": 40,
    "role": 35,
    "major": 15,
    "major_prior": 20,
    "timing": 10,
}

# 개인화 요소. 이 중 하나도 평가할 수 없으면 개인화 점수를 만들지 않는다.
PERSONAL_FACTORS = ("interest", "role", "major", "major_prior")

# 학과 통계 값이 이 이상이면 추천 이유(major_prior_match)를 붙인다.
# 값 1 = 그 학과에서 가장 많이 가는 직무·관심사. 0.5 = 그 절반 이상.
MAJOR_PRIOR_REASON_MIN = 0.5

# D-005 #8: 마감까지 남은 날짜(일) 상한 → 값. 마지막 구간은 상한 없음.
TIMING_BANDS = ((14, 1.0), (30, 0.6), (None, 0.3))

# 기본 추천에서 제외 (SPEC §6 추천 1)
EXCLUDED_LIFECYCLE = {"closed", "removed"}
EXCLUDED_PUBLICATION = {"review_pending"}
EXCLUDED_CATEGORIES = {"admin_notice"}  # 학생 대상이 아닌 행정 공지

# 마감일을 모르는(lifecycle unknown) 공고는 게시 후 이 일수가 지나면 기본 추천에서 뺀다 (D-013).
# 게시판 상단 고정 공지(몇 년 전 규정 안내 등)와 이미 끝났을 가능성이 큰 공고가 추천에 남지 않게 한다.
STALE_UNKNOWN_DAYS = 60

MAX_LIMIT = 50
