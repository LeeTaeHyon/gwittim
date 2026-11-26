"""위비티 대외활동 배치 실행 (D-038, D-059). 수집 → 파이프라인 → 분석 → 게시.

uv run python -m backend.collectors.wevity_activity --dry-run --pages 1 --max-items 3
옵션과 동작은 backend/collectors/common/external_cli.py 참고.
"""
from backend.collectors import wevity_activity
from backend.collectors.common.external_cli import main

if __name__ == "__main__":
    main(wevity_activity)
