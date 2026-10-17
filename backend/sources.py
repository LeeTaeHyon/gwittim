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


SOURCES: dict[str, SourceConfig] = {
    "mjc_www_notice": SourceConfig(
        source_id="mjc_www_notice",
        name="명지전문대학 공지사항",
        university_id="mjc",
        timezone="Asia/Seoul",
        timezone_basis="서울 소재 학교 게시판이며 본문 시각을 국내 시각으로 표기 (source-review §4). 시각이 있는 날짜에만 적용",
    ),
}


def source_config(source_id: str) -> SourceConfig:
    """등록되지 않은 출처는 시간대·학교를 미상으로 둔다."""
    return SOURCES.get(source_id) or SourceConfig(source_id, source_id, None, None, None)
