"""올콘 대학생·일반인 공모전 배치 실행 (D-038, D-059). 목록 JSON(POST) → 새 공고만 상세 → 파이프라인 → 분석 → 게시.

uv run python -m backend.collectors.allcon_contest --dry-run --pages 1 --max-items 3
옵션과 동작은 backend/collectors/common/external_cli.py 참고.
"""
from backend.collectors import allcon_contest
from backend.collectors.common.external_cli import main

if __name__ == "__main__":
    main(allcon_contest)
