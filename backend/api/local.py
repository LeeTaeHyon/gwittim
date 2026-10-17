"""로컬 개발 서버: 합성 fixtures 공고 + 개발용 토큰. 실제 인증·DB 없이 API를 띄운다.

uv run uvicorn backend.api.local:app --port 8000
curl -H "Authorization: Bearer dev-token" localhost:8000/v1/recommendations
"""
import json
from pathlib import Path

from .app import create_app
from .deps import Deps, FakeTokenVerifier, InMemoryNotices, InMemoryProfiles, InMemorySaved

_FIXTURES = Path(__file__).resolve().parents[2] / "fixtures/valid/notice"
_notices = {n["notice_id"]: n for n in (json.loads(p.read_text(encoding="utf-8")) for p in sorted(_FIXTURES.glob("*.json")))}

app = create_app(
    Deps(
        verifier=FakeTokenVerifier({"dev-token": "dev-user"}),
        notices=InMemoryNotices(_notices),
        profiles=InMemoryProfiles(),
        saved=InMemorySaved(),
    )
)
