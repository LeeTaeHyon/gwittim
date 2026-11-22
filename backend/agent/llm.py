"""LLM 제공자 겹 (docs/agent-privacy-spec.md §3).

환경변수 `GWITTIM_LLM_PROVIDER`로 고른다: `fake`(기본) / `cli` / `api` / `deepseek`.
네 제공자 모두 같은 형식의 리포트(4칸)를 돌려준다. 응답 JSON을 파싱해 4칸이 다 있는지 검사한다.
서비스 제공자는 `deepseek`(D-044, 2026-11-22). `api`(Anthropic)는 되돌릴 때를 위해 남겨 둔다.

- `cli`는 로컬 `claude -p` 하위 프로세스다. `K_SERVICE`(Cloud Run)가 있으면 거부한다. 앱 시작 때 `check_startup()`으로
  한 번 확인한다. 도구·MCP·슬래시 명령을 끄고 빈 임시 폴더에서 실행해, 공고 본문에 섞인 지시문이 로컬 파일을
  읽게 만들 수 없게 한다.
- `api`는 Anthropic Messages API를 urllib로 부른다. 키(`ANTHROPIC_API_KEY`)가 없으면 호출하지 않고 `ProviderNotReady`.
- `deepseek`는 DeepSeek Platform 공식 API(Chat Completions, 모델 `deepseek-flash` = V4.1 Flash)를 urllib로 부른다.
  키(`DEEPSEEK_API_KEY`)가 없으면 호출하지 않고 `ProviderNotReady`. JSON 스키마 강제가 없어 `json_object` 모드만 쓰고
  4칸은 `parse_report`로 검사한다. 추론 내용(reasoning_content)은 버린다. 생각은 끈다(`reasoning_effort: none`, 2026-11-22 비교: low 대비 약 3배 싸고 빠르며 품질 차이 없음).
- 외부 공고 찾기(웹 검색, D-047)는 `web_search`로 따로 부른다. deepseek만 실제로 검색하고, fake는 합성 결과,
  cli·api는 `ProviderNotReady`. DeepSeek 웹 검색 도구는 JSON 모드와 함께 쓸 수 없어(400) 지시문으로 JSON을 받고,
  검색 출처(server_tool_calls의 sources)를 함께 돌려준다. 결과 검증은 backend/agent/external.py가 한다.
- 공식 SDK는 쓰지 않음(2026-11-21). 요청 종류가 늘거나 스트리밍·도구 호출이 필요하면 SDK로 바꿈(새 라이브러리 승인 필요).
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
API_MAX_TOKENS = 8000  # Haiku 5.5의 생각 토큰도 이 안에서 쓴다
API_EFFORT = "low"
# 재시도: 429·529·500 이상·연결 오류만, 최대 2번 더. 대기 1초·2초(retry-after가 있으면 그 값, 최대 10초)
API_MAX_RETRIES = 2
API_RETRY_DELAYS = (1.0, 2.0)
API_RETRY_AFTER_MAX = 10.0
# 도구 전부 끔(--tools ""), 설정된 MCP 무시, 슬래시 명령·세션 저장 끔. 출력은 리포트 JSON 문자열만 필요하다.
CLI_COMMAND = (
    "claude", "-p", "--model", "haiku",
    "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
)
# 비용 추정용 가격(USD/MTok)과 환율. D-039 모델 비교 기록(tools/llm_compare.py) 기준. api 연결 직전 다시 확인(P9).
PRICE_INPUT_USD_PER_MTOK = 0.10
PRICE_OUTPUT_USD_PER_MTOK = 0.50
KRW_PER_USD = 1400
# deepseek(DeepSeek Platform): api-docs.deepseek.com 2026-11-22 확인
DEEPSEEK_KEY_ENV = "DEEPSEEK_API_KEY"
DEEPSEEK_URL = "https://api.deepseek.com/chat/completions"
DEEPSEEK_MODEL = "deepseek-flash"  # DeepSeek-V4.1-Flash-1017
DEEPSEEK_MAX_TOKENS = 8000  # 추론 토큰도 이 안에서 쓴다
DEEPSEEK_EFFORT = "none"  # 판정은 서버 규칙이 내리고 모델은 문장 정리만 하므로 생각을 끈다
# 단가(USD/MTok, 입력은 캐시 미적중 기준으로 넉넉히). 피크는 평일 UTC 01-04시·06-10시, 나머지는 절반.
# 중국 공휴일은 할인이지만 달력을 두지 않고 피크로 계산한다(월 상한 쪽으로 보수적).
DEEPSEEK_PRICE_PEAK = (0.30, 1.20)
DEEPSEEK_PRICE_OFF_PEAK = (0.15, 0.60)
DEEPSEEK_PEAK_HOURS_UTC = frozenset({1, 2, 3, 6, 7, 8, 9})
DEEPSEEK_SEARCH_MAX_TOKENS = 4000  # 외부 공고 찾기 답(최대 5개)
TIMEOUT_SECONDS = 120


def deepseek_prices(at: datetime) -> tuple[float, float]:
    """그 시각의 DeepSeek 입력·출력 단가(USD/MTok). at은 시간대가 있는 시각."""
    utc = at.astimezone(timezone.utc)
    peak = utc.weekday() < 5 and utc.hour in DEEPSEEK_PEAK_HOURS_UTC
    return DEEPSEEK_PRICE_PEAK if peak else DEEPSEEK_PRICE_OFF_PEAK


class LLMError(Exception):
    """제공자 겹의 공통 예외. 메시지에 프롬프트·응답·키를 넣지 않는다.

    호출은 했지만 실패했고 토큰 수를 알면 usage에 담긴다(비용 누적용).
    """

    usage: Usage | None = None


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
    price_input: float = PRICE_INPUT_USD_PER_MTOK  # 제공자별 추정 단가(USD/MTok)
    price_output: float = PRICE_OUTPUT_USD_PER_MTOK

    @property
    def cost_krw(self) -> float | None:
        return estimate_cost_krw(self.input_tokens, self.output_tokens, self.price_input, self.price_output)


@dataclass(frozen=True)
class LLMResult:
    report: dict
    usage: Usage = field(compare=False)


@dataclass(frozen=True)
class WebSearchResult:
    """웹 검색 호출 결과. text는 모델 답(검증 전), sources는 검색 도구가 실제로 본 페이지 목록.

    sources 항목: {"url", "title", "snippet", "site_name", "published_at"} (DeepSeek server_tool_calls 형식)
    """

    text: str
    sources: list[dict]
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


def estimate_cost_krw(
    input_tokens: int | None, output_tokens: int | None,
    price_input: float = PRICE_INPUT_USD_PER_MTOK, price_output: float = PRICE_OUTPUT_USD_PER_MTOK,
) -> float | None:
    """토큰 수로 추정한 비용(원). 토큰 수를 모르면 None(추정하지 않음)."""
    if input_tokens is None or output_tokens is None:
        return None
    usd = (input_tokens * price_input + output_tokens * price_output) / 1_000_000
    return round(usd * KRW_PER_USD, 2)


def _log(
    provider: str, notice_id: str | None, requested_at: datetime, elapsed: float,
    tin: int | None, tout: int | None, ok: bool,
    price_input: float = PRICE_INPUT_USD_PER_MTOK, price_output: float = PRICE_OUTPUT_USD_PER_MTOK,
) -> None:
    log.info(
        "llm requested_at=%s notice_id=%s provider=%s elapsed=%.2fs input_tokens=%s output_tokens=%s "
        "cost_krw=%s success=%s",
        requested_at.isoformat(timespec="seconds"), notice_id, provider, elapsed, tin, tout,
        estimate_cost_krw(tin, tout, price_input, price_output), ok,
    )


@dataclass
class _Call:
    """호출 한 번의 로그 메타. 프롬프트·응답은 담지 않는다."""

    provider: str
    notice_id: str | None
    requested_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    started: float = field(default_factory=time.monotonic)
    price_input: float = PRICE_INPUT_USD_PER_MTOK
    price_output: float = PRICE_OUTPUT_USD_PER_MTOK

    def fail(self, exc: LLMError, tin: int | None = None, tout: int | None = None) -> LLMError:
        elapsed = time.monotonic() - self.started
        _log(self.provider, self.notice_id, self.requested_at, elapsed, tin, tout, False,
             self.price_input, self.price_output)
        if tin is not None and tout is not None:
            exc.usage = Usage(self.provider, elapsed, tin, tout, self.price_input, self.price_output)
        return exc

    def finish(self, text: str, tin: int | None, tout: int | None) -> LLMResult:
        elapsed = time.monotonic() - self.started
        try:
            report = parse_report(text)
        except ReportFormatError as exc:
            raise self.fail(exc, tin, tout)
        _log(self.provider, self.notice_id, self.requested_at, elapsed, tin, tout, True,
             self.price_input, self.price_output)
        return LLMResult(report, Usage(self.provider, elapsed, tin, tout, self.price_input, self.price_output))


# 합성 문장. 명사형·합쇼체만 쓴다.
FAKE_REPORT = {
    FIT: "합성 예시입니다. 관심 분야가 공고와 겹치는 점과 학년 조건이 맞지 않을 수 있는 점을 함께 확인할 필요가 있음.",
    ELIGIBILITY: "합성 예시입니다. 재학생 대상이며 학과 제한은 공고 원문 확인이 필요함.",
    TODO: "합성 예시입니다. 신청서 작성, 증빙 서류 준비, 마감 전 제출 확인이 필요함.",
    SKILLS: "합성 예시입니다. 자료 정리 능력과 팀 협업 경험이 요구됨.",
}


# 외부 공고 찾기 합성 결과: 모델 답 3개 중 하나는 출처에 없는 주소(검증에서 빠져야 함)
FAKE_SEARCH_SOURCES = [
    {"url": "https://contest.example.invalid/view/1", "title": "합성 소프트웨어 공모전 참가자 모집",
     "snippet": "접수 기간 2026.11.20 ~ 2026.12.31 대학생 누구나 온라인 접수", "site_name": "합성 공모전 사이트",
     "published_at": None},
    {"url": "https://list.example.invalid/contests", "title": "공모전 목록",
     "snippet": "[합성 AI 아이디어 해커톤] 참가자 모집 | 2026.11.01 ~ 2026.12.15", "site_name": "합성 목록 사이트",
     "published_at": None},
]
FAKE_SEARCH_TEXT = json.dumps({"items": [
    {"title": "합성 소프트웨어 공모전", "url": "https://contest.example.invalid/view/1", "deadline": "2026-12-31",
     "reason": "합성 예시입니다. 관심 분야인 소프트웨어 개발과 이어지는 공모전입니다."},
    {"title": "합성 AI 아이디어 해커톤", "url": "https://made-up.example.invalid/", "deadline": "2026-12-15",
     "reason": "합성 예시입니다. 온라인으로 참여할 수 있습니다."},
    {"title": "출처에 없는 합성 대회", "url": "https://nowhere.example.invalid/", "deadline": "2026-12-20",
     "reason": "합성 예시입니다."},
]}, ensure_ascii=False)


class FakeProvider:
    name = "fake"

    def __init__(self, env: Mapping[str, str] | None = None):
        env = os.environ if env is None else env
        self._cloud_run = _on_cloud_run(env)

    def web_search(self, system: str, user: str) -> WebSearchResult:
        call = _Call(self.name, None)
        if self._cloud_run:
            raise call.fail(ProviderNotReady("Cloud Run에서는 fake 제공자를 쓸 수 없습니다"))
        return WebSearchResult(FAKE_SEARCH_TEXT, [dict(s) for s in FAKE_SEARCH_SOURCES], Usage(self.name, 0.0))

    def generate(self, system: str, user: str, notice_id: str | None = None) -> LLMResult:
        if self._cloud_run:  # 합성 리포트를 실사용자에게 주지 않는다. 시작은 막지 않고 호출 때 준비 중으로 답한다
            raise _Call(self.name, notice_id).fail(ProviderNotReady("Cloud Run에서는 fake 제공자를 쓸 수 없습니다"))
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


def _report_schema() -> dict:
    """구조화 출력용 JSON 스키마. 칸 이름은 REPORT_KEYS에서 만든다."""
    return {
        "type": "object",
        "properties": {k: {"type": "string"} for k in REPORT_KEYS},
        "required": list(REPORT_KEYS),
        "additionalProperties": False,
    }


def _retry_wait(attempt: int, headers) -> float:
    """재시도 전 대기(초). retry-after(초 단위 숫자)가 있으면 그 값, 최대 API_RETRY_AFTER_MAX."""
    wait = API_RETRY_DELAYS[min(attempt, len(API_RETRY_DELAYS) - 1)]
    raw = None
    try:
        for k, v in headers.items():
            if str(k).lower() == "retry-after":
                raw = v
                break
    except AttributeError:
        pass
    if raw is not None:
        try:
            wait = float(raw)
        except (TypeError, ValueError):
            pass
    return max(0.0, min(wait, API_RETRY_AFTER_MAX))


def _post_json(
    req: urllib.request.Request, call: _Call, label: str, timeout: float, sleep, clock,
    http_errors: Mapping[int, str] | None = None,
) -> dict:
    """재시도 포함 JSON 호출(api·deepseek 공통). 429·5xx·연결 오류만 최대 API_MAX_RETRIES번 더 부른다.

    전체 시간은 timeout을 넘기지 않는다. http_errors는 HTTP 코드별 메시지(원인 종류만, 키·원문 없음).
    """
    start = clock()
    for attempt in range(API_MAX_RETRIES + 1):
        remaining = timeout - (clock() - start)
        if remaining <= 0:
            raise call.fail(ProviderCallError(f"{label} 호출 시간이 초과되었습니다"))
        headers = {}
        try:
            with urllib.request.urlopen(req, timeout=remaining) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            msg = (http_errors or {}).get(e.code) or f"{label}가 HTTP {e.code}로 응답했습니다"
            failure = ProviderCallError(msg)
            if not (e.code == 429 or e.code >= 500):
                raise call.fail(failure) from None
            headers = getattr(e, "headers", None) or {}
        except (urllib.error.URLError, http.client.HTTPException, OSError, TimeoutError):
            failure = ProviderCallError(f"{label} 호출에 실패했습니다")
        except ValueError:
            raise call.fail(ReportFormatError(f"{label} 응답을 해석하지 못했습니다")) from None
        if attempt >= API_MAX_RETRIES:
            raise call.fail(failure) from None
        wait = _retry_wait(attempt, headers)
        if (clock() - start) + wait >= timeout:
            raise call.fail(failure) from None
        log.info("llm retry provider=%s count=%d", label, attempt + 1)
        sleep(wait)
    raise call.fail(ProviderCallError(f"{label} 호출에 실패했습니다"))  # 도달하지 않음


class ApiProvider:
    name = "api"

    def __init__(
        self, env: Mapping[str, str] | None = None, timeout: float = TIMEOUT_SECONDS,
        sleep=time.sleep, clock=time.monotonic,
    ):
        env = os.environ if env is None else env
        self._key = env.get(API_KEY_ENV, "").strip()
        self.timeout = timeout
        self._sleep = sleep  # 테스트에서 가짜로 바꾼다
        self._clock = clock

    def _post(self, req: urllib.request.Request, call: _Call) -> dict:
        """재시도 포함 호출. 전체 시간은 self.timeout을 넘기지 않는다."""
        return _post_json(req, call, self.name, self.timeout, self._sleep, self._clock)

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
                "output_config": {
                    "effort": API_EFFORT,
                    "format": {"type": "json_schema", "schema": _report_schema()},
                },
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
        payload = self._post(req, call)
        payload = payload if isinstance(payload, dict) else {}
        blocks = payload.get("content")
        text = ""
        if isinstance(blocks, list):  # thinking 블록은 버리고 text 블록만 쓴다
            text = "".join(b.get("text", "") for b in blocks if isinstance(b, dict) and b.get("type") == "text")
        usage = payload.get("usage")
        usage = usage if isinstance(usage, dict) else {}
        tin, tout = usage.get("input_tokens"), usage.get("output_tokens")
        tin = tin if isinstance(tin, int) else None
        tout = tout if isinstance(tout, int) else None
        stop = payload.get("stop_reason")
        if stop == "max_tokens":
            raise call.fail(ReportFormatError("api 응답이 최대 길이에서 잘렸습니다"), tin, tout)
        if stop == "refusal":
            raise call.fail(ProviderCallError("api가 안전 판단으로 거절했습니다"), tin, tout)
        return call.finish(text, tin, tout)


class DeepSeekProvider:
    name = "deepseek"

    def __init__(
        self, env: Mapping[str, str] | None = None, timeout: float = TIMEOUT_SECONDS,
        sleep=time.sleep, clock=time.monotonic,
    ):
        env = os.environ if env is None else env
        self._key = env.get(DEEPSEEK_KEY_ENV, "").strip()
        self.timeout = timeout
        self._sleep = sleep  # 테스트에서 가짜로 바꾼다
        self._clock = clock

    def generate(self, system: str, user: str, notice_id: str | None = None) -> LLMResult:
        call = _Call(self.name, notice_id)
        call.price_input, call.price_output = deepseek_prices(call.requested_at)
        if not self._key:
            raise call.fail(ProviderNotReady("deepseek 키가 없어 준비 중입니다"))
        body = json.dumps(
            {
                "model": DEEPSEEK_MODEL,
                "max_tokens": DEEPSEEK_MAX_TOKENS,
                "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                # json_object 모드는 지시문에 'json' 낱말과 형식 예시가 있어야 한다(SYSTEM_PROMPT '형식 예시(json)')
                "response_format": {"type": "json_object"},
                "reasoning_effort": DEEPSEEK_EFFORT,
            },
            ensure_ascii=False,
        ).encode("utf-8")
        req = urllib.request.Request(
            DEEPSEEK_URL,
            data=body,
            method="POST",
            headers={"Authorization": f"Bearer {self._key}", "Content-Type": "application/json"},
        )
        payload = _post_json(
            req, call, self.name, self.timeout, self._sleep, self._clock,
            http_errors={
                401: "deepseek 인증에 실패했습니다(키 없음 또는 무효)",
                402: "deepseek 잔액이 부족합니다",
            },
        )
        payload = payload if isinstance(payload, dict) else {}
        usage = payload.get("usage")
        usage = usage if isinstance(usage, dict) else {}
        tin, tout = usage.get("prompt_tokens"), usage.get("completion_tokens")
        tin = tin if isinstance(tin, int) else None
        tout = tout if isinstance(tout, int) else None
        choices = payload.get("choices")
        choice = choices[0] if isinstance(choices, list) and choices and isinstance(choices[0], dict) else {}
        message = choice.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        text = content if isinstance(content, str) else ""  # reasoning_content는 쓰지 않고 버린다
        finish = choice.get("finish_reason")
        if finish == "length":
            raise call.fail(ReportFormatError("deepseek 응답이 최대 길이에서 잘렸습니다"), tin, tout)
        if finish == "content_filter":
            raise call.fail(ProviderCallError("deepseek가 내용 필터로 응답을 막았습니다"), tin, tout)
        # JSON으로 인식되지 않은 출력은 공백으로 바뀌어 온다 -> parse_report가 ReportFormatError로 처리
        return call.finish(text, tin, tout)

    def web_search(self, system: str, user: str) -> WebSearchResult:
        """웹 검색 도구를 켠 호출 한 번(D-047). 검색은 DeepSeek 서버가 하고, 클라이언트 쪽 도구 실행은 없다.

        - 생각 끔(`thinking: disabled`) = 일반 웹 검색. 켜면 '깊은 검색'(최대 약 20번 호출)이라 느리고 비싸다
        - JSON 모드 불가(웹 도구와 함께 쓰면 400) → 지시문으로 JSON을 받고 서버가 검증한다
        - 사이트 제한(allowed_domains 등)은 지원하지 않는다(400) → 출처 검증으로 대신한다
        - 검색 자체는 2026-11-18부터 따로 과금하지 않고, 결과가 입력 토큰으로 잡힌다(약 1만 토큰)
        """
        call = _Call(self.name, None)
        call.price_input, call.price_output = deepseek_prices(call.requested_at)
        if not self._key:
            raise call.fail(ProviderNotReady("deepseek 키가 없어 준비 중입니다"))
        body = json.dumps(
            {
                "model": DEEPSEEK_MODEL,
                "max_tokens": DEEPSEEK_SEARCH_MAX_TOKENS,
                "thinking": {"type": "disabled"},
                "tools": [{"type": "deepseek_web_search"}],
                "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            },
            ensure_ascii=False,
        ).encode("utf-8")
        req = urllib.request.Request(
            DEEPSEEK_URL, data=body, method="POST",
            headers={"Authorization": f"Bearer {self._key}", "Content-Type": "application/json"},
        )
        payload = _post_json(
            req, call, self.name, self.timeout, self._sleep, self._clock,
            http_errors={401: "deepseek 인증에 실패했습니다(키 없음 또는 무효)", 402: "deepseek 잔액이 부족합니다"},
        )
        payload = payload if isinstance(payload, dict) else {}
        usage = payload.get("usage") if isinstance(payload.get("usage"), dict) else {}
        tin, tout = usage.get("prompt_tokens"), usage.get("completion_tokens")
        tin = tin if isinstance(tin, int) else None
        tout = tout if isinstance(tout, int) else None
        choices = payload.get("choices")
        choice = choices[0] if isinstance(choices, list) and choices and isinstance(choices[0], dict) else {}
        message = choice.get("message") if isinstance(choice.get("message"), dict) else {}
        finish = choice.get("finish_reason")
        if finish == "length":
            raise call.fail(ReportFormatError("deepseek 응답이 최대 길이에서 잘렸습니다"), tin, tout)
        if finish == "content_filter":
            raise call.fail(ProviderCallError("deepseek가 내용 필터로 응답을 막았습니다"), tin, tout)
        sources = []
        for step in message.get("server_tool_calls") or []:
            for c in (step.get("calls") or []) if isinstance(step, dict) else []:
                for src in (c.get("sources") or []) if isinstance(c, dict) else []:
                    if isinstance(src, dict) and isinstance(src.get("url"), str):
                        sources.append({k: src.get(k) for k in ("url", "title", "snippet", "site_name", "published_at")})
        text = message.get("content") if isinstance(message.get("content"), str) else ""
        elapsed = time.monotonic() - call.started
        _log(self.name, None, call.requested_at, elapsed, tin, tout, True, call.price_input, call.price_output)
        return WebSearchResult(text, sources, Usage(self.name, elapsed, tin, tout, call.price_input, call.price_output))

def get_provider(name: str | None = None, env: Mapping[str, str] | None = None) -> Provider:
    """제공자를 만든다. name이 없으면 GWITTIM_LLM_PROVIDER, 그것도 없으면 fake."""
    env = os.environ if env is None else env
    chosen = (name or env.get(PROVIDER_ENV) or DEFAULT_PROVIDER).strip().lower()
    if chosen == "fake":
        return FakeProvider(env)
    if chosen == "cli":
        return CliProvider(env)
    if chosen == "api":
        return ApiProvider(env)
    if chosen == "deepseek":
        return DeepSeekProvider(env)
    raise LLMError("알 수 없는 제공자입니다")


def check_startup(env: Mapping[str, str] | None = None) -> str:
    """앱 시작 때 한 번 부른다. 고른 제공자를 이 환경에서 쓸 수 없으면(Cloud Run의 cli 등) 예외로 시작을 막는다."""
    return get_provider(env=env).name


def generate_report(
    system: str, user: str, provider: Provider | None = None, notice_id: str | None = None,
) -> LLMResult:
    """공통 인터페이스: 시스템 지시문과 사용자 입력 -> 리포트 dict(4칸)와 사용량 메타. notice_id는 로그용."""
    return (provider or get_provider()).generate(system, user, notice_id=notice_id)
