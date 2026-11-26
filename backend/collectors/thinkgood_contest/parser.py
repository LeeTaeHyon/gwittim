"""씽굿(thinkcontest.com) 공모전 목록 JSON 파서. 표준 라이브러리만 쓴다.

목록은 JSON POST(/thinkgood/user/contest/subList.do) 응답이다(사이트 contest.js가 같은 주소로 부른다). 한 쪽 10건, 최신 등록 순,
접수 끝난 옛 공고도 이어진다(2026-11-26 totalcnt 70,653). 각 항목에 본문(competition_syllabus, HTML)까지 들어 있어 상세 페이지는 열지 않는다.
process: ING 접수중 · INGEND 마감임박(아직 접수 중) · YET 접수예정 · END 마감.
담당자 이름·연락처·이메일(manager, position, contact, email)은 읽지 않는다.
"""
from __future__ import annotations

import json
from dataclasses import dataclass

from backend.collectors.common.external import clean_text


@dataclass
class ListRow:
    pk: str
    item: dict

    @property
    def ended(self) -> bool:
        return self.item.get("process") == "END"

    @property
    def audience(self) -> str:
        return clean_text(self.item.get("enter_qualified_nm") or "")


def parse_list(text: str) -> list[ListRow]:
    """응답 JSON → 행. status가 1이 아니거나 형식이 다르면 빈 목록(구조 변경 의심으로 기록됨)."""
    try:
        data = json.loads(text)
    except ValueError:
        return []
    if str(data.get("status")) != "1":
        return []
    return [ListRow(str(x["contest_pk"]), x) for x in data.get("listJsonData") or [] if x.get("contest_pk")]
