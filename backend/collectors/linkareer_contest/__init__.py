"""링커리어 공모전 메뉴 (D-038, D-059). 파서·조립은 backend/collectors/linkareer 공통 부품을 쓴다."""
from backend.collectors.linkareer.adapter import make_collect, make_source
from backend.collectors.linkareer.parser import TYPE_CONTEST, parse_detail, parse_list

SOURCE_ID = "linkareer_contest"
SOURCE = make_source(SOURCE_ID, "contest", TYPE_CONTEST, contest=True)
collect = make_collect(SOURCE)

__all__ = ["SOURCE", "SOURCE_ID", "collect", "parse_detail", "parse_list"]
