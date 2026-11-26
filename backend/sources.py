"""출처 설정. 시간대 적용 근거를 출처별로 남긴다 (SPEC §5 공통 규칙).

어댑터(W2)가 추가될 때 게시판 설정(menu_idx 등)도 이 설정 옆에 둔다.
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class SourceConfig:
    source_id: str
    name: str
    university_id: str | None
    timezone: str | None
    timezone_basis: str | None


_MJC_TIMEZONE_BASIS = "서울 소재 학교 게시판이며 본문 시각을 국내 시각으로 표기 (source-review §4). 시각이 있는 날짜에만 적용"

# D-045: 서울 소재 학교 게시판이며 본문 시각을 국내 시각으로 표기한다. 2026-11-22 수집기 시험에서 상세 표본으로 확인(시각은 '14시'처럼 한국어로 쓰고 시간대 표기는 없음)
_SEWU_TIMEZONE_BASIS = "서울 소재 학교 게시판이며 본문 시각을 국내 시각으로 표기 (D-045). 시각이 있는 날짜에만 적용. 상세 표본에서 확인 (D-045 수집기 시험)"

# D-019: 팀장 PC(한국 시각)의 카톡에서 내보낸 대화. 메시지 시각과 본문 속 날짜를 국내 시각으로 본다
_KAKAO_TIMEZONE_BASIS = "PC 카톡 대화 내보내기의 메시지 시각은 내보낸 PC(한국 시각) 기준이고, 학교 채널 본문 시각도 국내 시각으로 표기"

# D-038 교외 공모전 출처. 접수 기간은 날짜만 표기하고 본문 시각은 주최 측이 쓴 것이라(해외 주최 가능) 시간대를 확인할 수 없다.
# 그래서 시간대를 정하지 않는다(null). 시각이 있는 날짜는 시각만 남고 시간대는 미상으로 보존된다 (SPEC §5)
_EXTERNAL_TIMEZONE_BASIS = None

# D-058 사용자가 카카오톡에서 직접 넘긴 공고. 어느 학교·시간대인지 확인할 수 없어 둘 다 정하지 않는다(null)
_USER_SHARE_TIMEZONE_BASIS = None

SOURCES: dict[str, SourceConfig] = {
    s.source_id: s
    for s in [
        SourceConfig("mjc_www_notice", "명지전문대학 공지사항", "mjc", "Asia/Seoul", _MJC_TIMEZONE_BASIS),
        SourceConfig("mjc_www_scholarship", "명지전문대학 장학공지", "mjc", "Asia/Seoul", _MJC_TIMEZONE_BASIS),
        SourceConfig("mjc_www_job", "명지전문대학 채용공지", "mjc", "Asia/Seoul", _MJC_TIMEZONE_BASIS),
        SourceConfig("mjc_www_work", "명지전문대학 근로게시판", "mjc", "Asia/Seoul", _MJC_TIMEZONE_BASIS),
        SourceConfig("mjc_kakao", "명지전문대학 카카오톡 알림톡", "mjc", "Asia/Seoul", _KAKAO_TIMEZONE_BASIS),
        SourceConfig("sewu_www_notice", "숭의여대 공지", "sewu", "Asia/Seoul", _SEWU_TIMEZONE_BASIS),
        SourceConfig("wevity_contest", "위비티", None, None, _EXTERNAL_TIMEZONE_BASIS),
        SourceConfig("contestkorea_contest", "콘테스트코리아", None, None, _EXTERNAL_TIMEZONE_BASIS),
        SourceConfig("user_share", "카카오톡에서 넘긴 공고", None, None, _USER_SHARE_TIMEZONE_BASIS),
    ]
}


def source_config(source_id: str) -> SourceConfig:
    """등록되지 않은 출처는 시간대·학교를 미상으로 둔다."""
    return SOURCES.get(source_id) or SourceConfig(source_id, source_id, None, None, None)
