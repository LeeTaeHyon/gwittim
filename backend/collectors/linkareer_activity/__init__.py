"""링커리어 대외활동 메뉴 (D-038, D-059). 파서·조립은 backend/collectors/linkareer 공통 부품을 쓴다."""
from backend.collectors.linkareer.adapter import make_collect, make_source
from backend.collectors.linkareer.parser import TYPE_ACTIVITY, parse_detail, parse_list

SOURCE_ID = "linkareer_activity"
SOURCE = make_source(SOURCE_ID, "activity", TYPE_ACTIVITY, contest=False)
collect = make_collect(SOURCE)

__all__ = ["SOURCE", "SOURCE_ID", "collect", "parse_detail", "parse_list"]
