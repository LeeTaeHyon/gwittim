"""LLM 제공자 겹 (docs/agent-privacy-spec.md §3).

환경변수 `GWITTIM_LLM_PROVIDER`로 고른다: `fake`(기본) / `cli` / `api`.
세 제공자 모두 같은 형식의 리포트(4칸)를 돌려준다. 응답 JSON을 파싱해 4칸이 다 있는지 검사한다.

- `cli`는 로컬 `claude -p` 하위 프로세스다. `K_SERVICE`(Cloud Run)가 있으면 거부한다. 앱 시작 때 `check_startup()`으로
  한 번 확인한다. 도구·MCP·슬래시 명령을 끄고 빈 임시 폴더에서 실행해, 공고 본문에 섞인 지시문이 로컬 파일을
  읽게 만들 수 없게 한다.
- `api`는 Anthropic Messages API를 urllib로 부른다. 키(`ANTHROPIC_API_KEY`)가 없으면 호출하지 않고 `ProviderNotReady`.
- 프롬프트·응답 원문과 키 값은 로그·예외 메시지에 넣지 않는다.
  로그에는 명세 §3의 요청 시각·공고 id·토큰 수·비용·성공 여부와 제공자 이름·소요 시간만 남긴다.
"""
from __future__ import annotations

import http.client
import json
import logging
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Mapping, Protocol

log = logging.getLogger("gwittim.agent.llm")

# 리포트 칸 4개 (명세 §11.2). 순서는 화면 순서와 같다.
FIT = "fit"  # 나에게 맞는 점·안 맞는 점
ELIGIBILITY = "eligibility"  # 지원 자격
TODO = "todo"  # 지원 전 할 일
SKILLS = "skills"  # 필요한 역량
REPORT_KEYS = (FIT, ELIGIBILITY, TODO, SKILLS)

PROVIDER_ENV = "GWITTIM_LLM_PROVIDER"
DEFAULT_PROVIDER = "fake"
API_KEY_ENV = "ANTHROPIC_API_KEY"
API_URL = "https://api.anthropic.com/v1/messages"
API_VERSION = "2023-06-01"
API_MODEL = "claude-haiku-5-5"
API_MAX_TOKENS = 2000
# 도구 전부 끔(--tools ""), 설정된 MCP 무시, 슬래시 명령·세션 저장 끔. 출력은 리포트 JSON 문자열만 필요하다.
CLI_COMMAND = (
    "claude", "-p", "--model", "haiku",
    "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
)
# 비용 추정용 가격(USD/MTok)과 환율. D-039 모델 비교 기록(tools/llm_compare.py) 기준. api 연결 직전 다시 확인(P9).
PRICE_INPUT_USD_PER_MTOK = 0.10
PRICE_OUTPUT_USD_PER_MTOK = 0.50
KRW_PER_USD = 1400
TIMEOUT_SECONDS = 120


class LLMError(Exception):
    """제공자 겹의 공통 예외. 메시지에 프롬프트·응답·키를 넣지 않는다."""


class ProviderRefused(LLMError):
    """이 환경에서 쓸 수 없는 제공자 (예: Cloud Run에서 cli)."""


class ProviderNotReady(LLMError):
    """준비 중: api 키가 아직 없음. 호출하지 않았다."""


class ProviderCallError(LLMError):
    """호출 실패 (시간 초과, 실행 불가, HTTP 오류 등)."""


class ReportFormatError(LLMError):
    """응답이 JSON이 아니거나 리포트 4칸이 빠짐."""


@dataclass(frozen=True)
class Usage:
    provider: str
    elapsed_seconds: float
    input_tokens: int | None = None
    output_tokens: int | None = None


@dataclass(frozen=True)
class LLMResult:
    report: dict
    usage: Usage = field(compare=False)


class Provider(Protocol):
    name: str

    def generate(self, system: str, user: str, notice_id: str | None = None) -> LLMResult: ...


def extract_json(text: str) -> dict:
    """응답 문자열에서 JSON 객체를 꺼낸다 (앞뒤 설명·코드 펜스 허용)."""
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        raise ReportFormatError("응답에서 JSON 객체를 찾지 못했습니다")
    try:
        data = json.loads(text[start : end + 1])
    except ValueError:
        raise ReportFormatError("응답 JSON을 해석하지 못했습니다") from None
    if not isinstance(data, dict):
        raise ReportFormatError("응답 JSON이 객체가 아닙니다")
    return data


def parse_report(text: str) -> dict:
    """응답 문자열 -> 리포트 dict(4칸만). 칸이 빠졌거나 비어 있으면 ReportFormatError."""
    data = extract_json(text)
    missing = [k for k in REPORT_KEYS if k not in data or data[k] in (None, "", [], {})]
    if missing:
        raise ReportFormatError("리포트 칸이 빠졌습니다: " + ", ".join(missing))
    return {k: data[k] for k in REPORT_KEYS}


def estimate_cost_krw(input_tokens: int | None, output_tokens: int | None) -> float | None:
    """토큰 수로 추정한 비용(원). 토큰 수를 모르면 None(추정하지 않음)."""
    if input_tokens is None or output_tokens is None:
        return None
    usd = (input_tokens * PRICE_INPUT_USD_PER_MTOK + output_tokens * PRICE_OUTPUT_USD_PER_MTOK) / 1_000_000
    return round(usd * KRW_PER_USD, 2)


def _log(
    provider: str, notice_id: str | None, requested_at: datetime, elapsed: float,
    tin: int | None, tout: int | None, ok: bool,
) -> None:
    log.info(
        "llm requested_at=%s notice_id=%s provider=%s elapsed=%.2fs input_tokens=%s output_tokens=%s "
        "cost_krw=%s success=%s",
        requested_at.isoformat(timespec="seconds"), notice_id, provider, elapsed, tin, tout,
        estimate_cost_krw(tin, tout), ok,
    )


@dataclass
class _Call:
    """호출 한 번의 로그 메타. 프롬프트·응답은 담지 않는다."""

    provider: str
    notice_id: str | None
    requested_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    started: float = field(default_factory=time.monotonic)

    def fail(self, exc: LLMError) -> LLMError:
        _log(self.provider, self.notice_id, self.requested_at, time.monotonic() - self.started, None, None, False)
        return exc

    def finish(self, text: str, tin: int | None, tout: int | None) -> LLMResult:
        elapsed = time.monotonic() - self.started
        try:
            report = parse_report(text)
        except ReportFormatError:
            _log(self.provider, self.notice_id, self.requested_at, elapsed, tin, tout, False)
            raise
        _log(self.provider, self.notice_id, self.requested_at, elapsed, tin, tout, True)
        return LLMResult(report, Usage(self.provider, elapsed, tin, tout))


# 합성 문장. 명사형·합쇼체만 쓴다.
FAKE_REPORT = {
    FIT: "합성 예시입니다. 관심 분야가 공고와 겹치는 점과 학년 조건이 맞지 않을 수 있는 점을 함께 확인할 필요가 있음.",
    ELIGIBILITY: "합성 예시입니다. 재학생 대상이며 학과 제한은 공고 원문 확인이 필요함.",
    TODO: "합성 예시입니다. 신청서 작성, 증빙 서류 준비, 마감 전 제출 확인이 필요함.",
    SKILLS: "합성 예시입니다. 자료 정리 능력과 팀 협업 경험이 요구됨.",
}


class FakeProvider:
    name = "fake"

    def generate(self, system: str, user: str, notice_id: str | None = None) -> LLMResult:
        return _Call(self.name, notice_id).finish(json.dumps(FAKE_REPORT, ensure_ascii=False), None, None)


def _on_cloud_run(env: Mapping[str, str]) -> bool:
    """Cloud Run은 K_SERVICE를 둔다. 값이 비어 있어도 있으면 Cloud Run으로 본다."""
    return "K_SERVICE" in env


class CliProvider:
    name = "cli"

    def __init__(self, env: Mapping[str, str] | None = None, timeout: float = TIMEOUT_SECONDS):
        env = os.environ if env is None else env
        if _on_cloud_run(env):
            raise ProviderRefused("cli 제공자는 Cloud Run에서 사용할 수 없습니다")
        self.timeout = timeout

    def generate(self, system: str, user: str, notice_id: str | None = None) -> LLMResult:
        call = _Call(self.name, notice_id)
        exe = shutil.which(CLI_COMMAND[0])
        if exe is None:
            raise call.fail(ProviderCallError("claude 실행 파일을 찾지 못했습니다"))
        cmd = [exe, *CLI_COMMAND[1:], "--system-prompt", system]
        try:
            # 빈 임시 폴더에서 실행: 저장소의 CLAUDE.md·파일이 작업 폴더로 잡히지 않게 한다.
            with tempfile.TemporaryDirectory(prefix="gwittim-llm-") as workdir:
                proc = subprocess.run(
                    cmd, input=user, capture_output=True, text=True, encoding="utf-8",
                    timeout=self.timeout, check=False, cwd=workdir,
                )
        except subprocess.TimeoutExpired:
            raise call.fail(ProviderCallError("claude 호출 시간이 초과되었습니다")) from None
        except OSError:
            raise call.fail(ProviderCallError("claude 실행에 실패했습니다")) from None
        if proc.returncode != 0:
            raise call.fail(ProviderCallError(f"claude가 오류 코드 {proc.returncode}로 끝났습니다"))
        return call.finish(proc.stdout or "", None, None)


class ApiProvider:
    name = "api"

    def __init__(self, env: Mapping[str, str] | None = None, timeout: float = TIMEOUT_SECONDS):
        env = os.environ if env is None else env
        self._key = env.get(API_KEY_ENV, "").strip()
        self.timeout = timeout

    def generate(self, system: str, user: str, notice_id: str | None = None) -> LLMResult:
        call = _Call(self.name, notice_id)
        if not self._key:
            raise call.fail(ProviderNotReady("api 키가 없어 준비 중입니다"))
        body = json.dumps(
            {
                "model": API_MODEL,
                "max_tokens": API_MAX_TOKENS,
                "system": system,
                "messages": [{"role": "user", "content": user}],
            },
            ensure_ascii=False,
        ).encode("utf-8")
        req = urllib.request.Request(
            API_URL,
            data=body,
            method="POST",
            headers={
                "x-api-key": self._key,
                "anthropic-version": API_VERSION,
                "content-type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            raise call.fail(ProviderCallError(f"api가 HTTP {e.code}로 응답했습니다")) from None
        except (urllib.error.URLError, http.client.HTTPException, OSError, TimeoutError):
            raise call.fail(ProviderCallError("api 호출에 실패했습니다")) from None
        except ValueError:
            raise call.fail(ReportFormatError("api 응답을 해석하지 못했습니다")) from None
        payload = payload if isinstance(payload, dict) else {}
        blocks = payload.get("content")
        text = ""
        if isinstance(blocks, list):
            text = "".join(b.get("text", "") for b in blocks if isinstance(b, dict) and b.get("type") == "text")
        usage = payload.get("usage")
        usage = usage if isinstance(usage, dict) else {}
        tin, tout = usage.get("input_tokens"), usage.get("output_tokens")
        return call.finish(text, tin if isinstance(tin, int) else None, tout if isinstance(tout, int) else None)


def get_provider(name: str | None = None, env: Mapping[str, str] | None = None) -> Provider:
    """제공자를 만든다. name이 없으면 GWITTIM_LLM_PROVIDER, 그것도 없으면 fake."""
    env = os.environ if env is None else env
    chosen = (name or env.get(PROVIDER_ENV) or DEFAULT_PROVIDER).strip().lower()
    if chosen == "fake":
        return FakeProvider()
    if chosen == "cli":
        return CliProvider(env)
    if chosen == "api":
        return ApiProvider(env)
    raise LLMError("알 수 없는 제공자입니다")


def check_startup(env: Mapping[str, str] | None = None) -> str:
    """앱 시작 때 한 번 부른다. 고른 제공자를 이 환경에서 쓸 수 없으면(Cloud Run의 cli 등) 예외로 시작을 막는다."""
    return get_provider(env=env).name


def generate_report(
    system: str, user: str, provider: Provider | None = None, notice_id: str | None = None,
) -> LLMResult:
    """공통 인터페이스: 시스템 지시문과 사용자 입력 -> 리포트 dict(4칸)와 사용량 메타. notice_id는 로그용."""
    return (provider or get_provider()).generate(system, user, notice_id=notice_id)
