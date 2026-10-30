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

# D-016: 팀장 PC(한국 시각)의 카톡에서 내보낸 대화. 메시지 시각과 본문 속 날짜를 국내 시각으로 본다
_KAKAO_TIMEZONE_BASIS = "PC 카톡 대화 내보내기의 메시지 시각은 내보낸 PC(한국 시각) 기준이고, 학교 채널 본문 시각도 국내 시각으로 표기"

SOURCES: dict[str, SourceConfig] = {
    s.source_id: s
    for s in [
        SourceConfig("mjc_www_notice", "명지전문대학 공지사항", "mjc", "Asia/Seoul", _MJC_TIMEZONE_BASIS),
        SourceConfig("mjc_www_scholarship", "명지전문대학 장학공지", "mjc", "Asia/Seoul", _MJC_TIMEZONE_BASIS),
        SourceConfig("mjc_www_job", "명지전문대학 채용공지", "mjc", "Asia/Seoul", _MJC_TIMEZONE_BASIS),
        SourceConfig("mjc_www_work", "명지전문대학 근로게시판", "mjc", "Asia/Seoul", _MJC_TIMEZONE_BASIS),
        SourceConfig("mjc_kakao", "명지전문대학 카카오톡 알림톡", "mjc", "Asia/Seoul", _KAKAO_TIMEZONE_BASIS),
    ]
}


def source_config(source_id: str) -> SourceConfig:
    """등록되지 않은 출처는 시간대·학교를 미상으로 둔다."""
    return SOURCES.get(source_id) or SourceConfig(source_id, source_id, None, None, None)
