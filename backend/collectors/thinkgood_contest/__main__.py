"""씽굿 공모전 배치 실행 (D-038, D-059). 목록 JSON(POST) → 파이프라인 → 분석 → 게시.

uv run python -m backend.collectors.thinkgood_contest --dry-run --pages 1
옵션과 동작은 backend/collectors/common/external_cli.py 참고.
"""
from backend.collectors import thinkgood_contest
from backend.collectors.common.external_cli import main

if __name__ == "__main__":
    main(thinkgood_contest)
