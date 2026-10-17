# 귀띔 서버 API (Cloud Run, D-004). 배포는 팀장의 별도 요청 후.
# docker build -t gwittim-api .
# docker run -p 8080:8080 -e GWITTIM_FIREBASE_PROJECT_ID=<id> gwittim-api
FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:0.12.5 /uv /usr/local/bin/uv

WORKDIR /app
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy PYTHONUNBUFFERED=1

# 의존성만 먼저 (캐시)
COPY pyproject.toml uv.lock .python-version ./
RUN uv sync --frozen --no-dev --no-install-project

# 서버에 필요한 코드와 계약만 복사 (앱·문서·fixtures 제외)
COPY backend ./backend
COPY contracts ./contracts

RUN useradd --create-home --uid 10001 app
USER app

# Cloud Run은 PORT 환경변수를 준다. 인증은 서비스 계정 ADC (키 파일 없음, SPEC §10)
CMD ["sh", "-c", "exec /app/.venv/bin/uvicorn backend.api.server:app --host 0.0.0.0 --port ${PORT:-8080}"]
