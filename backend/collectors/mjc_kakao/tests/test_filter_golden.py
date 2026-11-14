"""알림톡 종류 판정·가림 골든(filter_golden.json)이 지금 파서 결과와 같은지 (D-034).

기기 안 이식(apps/mobile/lib/classifier/kakao_filter.dart)은 같은 파일로 검사한다.
파서 규칙을 바꿔 이 테스트가 깨지면 `uv run python tools/make_kakao_filter_golden.py`로 다시 만든다.
"""
import json

from tools import make_kakao_filter_golden as golden


def test_golden_matches_parser():
    saved = json.loads(golden.OUT.read_text(encoding="utf-8"))
    assert saved == golden.build()


def test_golden_covers_every_kind():
    kinds = {c["kind"] for c in golden.build()["cases"]}
    assert kinds == {"broadcast", "personal_course", "personal_account", "participant", "noise"}
