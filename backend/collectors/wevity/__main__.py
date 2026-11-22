"""위비티 공모전 배치 실행 (D-038). 수집 → 파이프라인 → 분석 → 게시. 하루 2번 정기 배치 시각에 돈다.

uv run python -m backend.collectors.wevity                       # 로컬 파일만 (data/local/)
uv run python -m backend.collectors.wevity --dry-run --pages 1 --max-items 3   # 저장·게시 없이 파싱 건수만
GWITTIM_FIREBASE_PROJECT_ID=<id> uv run python -m backend.collectors.wevity   # Firestore에 게시
옵션과 동작은 backend/collectors/common/external_cli.py 참고.
"""
from backend.collectors import wevity
from backend.collectors.common.external_cli import main

if __name__ == "__main__":
    main(wevity)
