import io
import json
import logging
import subprocess
import urllib.error
import urllib.request

import pytest

from backend.agent import llm

SECRET_KEY = "sk-ant-test-SECRET-1234"
PROMPT = "비밀프롬프트-홍길동-gil@example.com"
SYSTEM = "시스템지시-고유문자열"
REPORT = {k: f"{k} 내용입니다" for k in llm.REPORT_KEYS}


class FakeResp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def api_provider():
    return llm.get_provider("api", env={"ANTHROPIC_API_KEY": SECRET_KEY})


def mock_urlopen(monkeypatch, text, seen=None):
    def fake(req, timeout=None):
        if seen is not None:
            seen["req"] = req
        body = {"content": [{"type": "text", "text": text}], "usage": {"input_tokens": 11, "output_tokens": 22}}
        return FakeResp(json.dumps(body).encode())

    monkeypatch.setattr(urllib.request, "urlopen", fake)


def test_default_provider_is_fake(monkeypatch):
    monkeypatch.delenv("GWITTIM_LLM_PROVIDER", raising=False)
    assert llm.get_provider().name == "fake"


def test_report_keys_order():
    assert llm.REPORT_KEYS == ("fit", "eligibility", "todo", "skills")


def test_fake_returns_four_fields():
    res = llm.generate_report(SYSTEM, PROMPT, llm.get_provider("fake", env={}))
    assert list(res.report) == list(llm.REPORT_KEYS)
    assert all(isinstance(v, str) and v for v in res.report.values())
    assert res.usage.provider == "fake"
    assert res.usage.elapsed_seconds >= 0


def test_cli_refused_on_cloud_run():
    with pytest.raises(llm.ProviderRefused):
        llm.get_provider("cli", env={"K_SERVICE": "gwittim-api"})


def test_cli_parses_stdout_and_passes_input_by_stdin(monkeypatch):
    seen = {}

    def fake_run(cmd, **kw):
        seen.update(cmd=cmd, **kw)
        return subprocess.CompletedProcess(cmd, 0, stdout="결과:\n```json\n" + json.dumps(REPORT) + "\n```", stderr="")

    monkeypatch.setattr(llm.shutil, "which", lambda n: "/bin/claude")
    monkeypatch.setattr(llm.subprocess, "run", fake_run)
    res = llm.get_provider("cli", env={}).generate(SYSTEM, PROMPT)
    assert res.report == REPORT
    assert seen["input"] == PROMPT
    assert PROMPT not in seen["cmd"]
    assert seen["timeout"] > 0


def test_cli_timeout_is_call_error(monkeypatch):
    def fake_run(cmd, **kw):
        raise subprocess.TimeoutExpired(cmd, 1)

    monkeypatch.setattr(llm.shutil, "which", lambda n: "/bin/claude")
    monkeypatch.setattr(llm.subprocess, "run", fake_run)
    with pytest.raises(llm.ProviderCallError):
        llm.get_provider("cli", env={}).generate(SYSTEM, PROMPT)


def test_api_without_key_is_not_ready(monkeypatch):
    def boom(*a, **k):
        raise AssertionError("키 없이 호출함")

    monkeypatch.setattr(urllib.request, "urlopen", boom)
    with pytest.raises(llm.ProviderNotReady):
        llm.get_provider("api", env={}).generate(SYSTEM, PROMPT)


def test_api_success_parses_and_sends_key(monkeypatch):
    seen = {}
    mock_urlopen(monkeypatch, "설명 " + json.dumps(REPORT, ensure_ascii=False), seen)
    res = api_provider().generate(SYSTEM, PROMPT)
    assert res.report == REPORT
    assert (res.usage.input_tokens, res.usage.output_tokens) == (11, 22)
    req = seen["req"]
    assert req.full_url == "https://api.anthropic.com/v1/messages"
    headers = {k.lower(): v for k, v in req.header_items()}
    assert headers["x-api-key"] == SECRET_KEY
    assert headers["anthropic-version"] == "2023-06-01"
    assert headers["content-type"] == "application/json"
    sent = json.loads(req.data)
    assert sent["model"] == "claude-haiku-5-5" and sent["system"] == SYSTEM
    assert sent["messages"] == [{"role": "user", "content": PROMPT}]


def test_missing_field_is_format_error(monkeypatch):
    partial = {k: v for k, v in REPORT.items() if k != "todo"}
    mock_urlopen(monkeypatch, json.dumps(partial))
    with pytest.raises(llm.ReportFormatError):
        api_provider().generate(SYSTEM, PROMPT)


def test_non_json_is_format_error(monkeypatch):
    mock_urlopen(monkeypatch, "JSON 없음")
    with pytest.raises(llm.ReportFormatError):
        api_provider().generate(SYSTEM, PROMPT)


def test_http_error_message_has_no_secret(monkeypatch):
    def fake(req, timeout=None):
        raise urllib.error.HTTPError(req.full_url, 401, "bad " + SECRET_KEY, {}, io.BytesIO(PROMPT.encode()))

    monkeypatch.setattr(urllib.request, "urlopen", fake)
    with pytest.raises(llm.ProviderCallError) as e:
        api_provider().generate(SYSTEM, PROMPT)
    assert SECRET_KEY not in str(e.value) and PROMPT not in str(e.value)


def test_logs_have_no_prompt_or_key(monkeypatch, caplog):
    caplog.set_level(logging.DEBUG)
    mock_urlopen(monkeypatch, json.dumps(REPORT, ensure_ascii=False))
    api_provider().generate(SYSTEM, PROMPT)
    mock_urlopen(monkeypatch, "깨진 응답 " + PROMPT)
    with pytest.raises(llm.ReportFormatError):
        api_provider().generate(SYSTEM, PROMPT)
    llm.get_provider("fake", env={}).generate(SYSTEM, PROMPT)
    text = caplog.text
    assert "provider=api" in text and "success=True" in text and "success=False" in text
    for secret in (SECRET_KEY, PROMPT, SYSTEM, "홍길동", REPORT["fit"]):
        assert secret not in text


def test_cli_disables_tools_and_runs_in_empty_temp_dir(monkeypatch):
    seen = {}

    def fake_run(cmd, **kw):
        import os
        seen.update(cmd=cmd, cwd=kw.get("cwd"), files=os.listdir(kw["cwd"]))
        return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(REPORT), stderr="")

    monkeypatch.setattr(llm.shutil, "which", lambda n: "/bin/claude")
    monkeypatch.setattr(llm.subprocess, "run", fake_run)
    llm.get_provider("cli", env={}).generate(SYSTEM, PROMPT)
    cmd = seen["cmd"]
    i = cmd.index("--tools")
    assert cmd[i + 1] == ""  # 도구 전부 끔
    for flag in ("--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence"):
        assert flag in cmd
    assert "gwittim-llm-" in seen["cwd"] and seen["files"] == []  # 빈 임시 폴더
    import os
    assert not os.path.exists(seen["cwd"])  # 끝나면 지움


def test_cli_refused_when_k_service_present_even_empty():
    with pytest.raises(llm.ProviderRefused):
        llm.get_provider("cli", env={"K_SERVICE": ""})


def test_check_startup_blocks_cli_on_cloud_run():
    env = {"GWITTIM_LLM_PROVIDER": "cli", "K_SERVICE": "gwittim-api"}
    with pytest.raises(llm.ProviderRefused):
        llm.check_startup(env)
    assert llm.check_startup({"GWITTIM_LLM_PROVIDER": "cli"}) == "cli"
    assert llm.check_startup({}) == "fake"


def test_log_has_spec_fields_notice_id_and_cost(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    mock_urlopen(monkeypatch, json.dumps(REPORT, ensure_ascii=False))  # 토큰 11, 22
    llm.generate_report(SYSTEM, PROMPT, api_provider(), notice_id="mjc.www.12345")
    text = caplog.text
    assert "notice_id=mjc.www.12345" in text
    assert "requested_at=" in text and "+00:00" in text
    assert "input_tokens=11 output_tokens=22" in text
    assert f"cost_krw={llm.estimate_cost_krw(11, 22)}" in text and "success=True" in text


def test_estimate_cost_krw():
    # (1,000,000 x 0.10 + 1,000,000 x 0.50) / 1,000,000 USD x 1,400원
    assert llm.estimate_cost_krw(1_000_000, 1_000_000) == 840.0
    assert llm.estimate_cost_krw(None, 22) is None  # 토큰 수 모르면 추정하지 않음


def test_api_incomplete_read_is_call_error(monkeypatch):
    import http.client

    def fake(req, timeout=None):
        raise http.client.IncompleteRead(b"partial")

    monkeypatch.setattr(urllib.request, "urlopen", fake)
    with pytest.raises(llm.ProviderCallError):
        api_provider().generate(SYSTEM, PROMPT)


# ---------- 요청 본문·stop_reason ----------

def test_request_body_has_effort_schema_and_max_tokens(monkeypatch):
    seen = {}
    mock_urlopen(monkeypatch, json.dumps(REPORT, ensure_ascii=False), seen)
    api_provider().generate(SYSTEM, PROMPT)
    sent = json.loads(seen["req"].data)
    assert sent["max_tokens"] == 8000
    assert "effort" not in sent and "temperature" not in sent
    cfg = sent["output_config"]
    assert cfg["effort"] == "low"
    assert cfg["format"]["type"] == "json_schema"
    schema = cfg["format"]["schema"]
    assert schema["type"] == "object" and schema["additionalProperties"] is False
    assert tuple(schema["required"]) == llm.REPORT_KEYS
    assert tuple(schema["properties"]) == llm.REPORT_KEYS
    assert all(v == {"type": "string"} for v in schema["properties"].values())


def mock_payload(monkeypatch, payload):
    monkeypatch.setattr(urllib.request, "urlopen", lambda req, timeout=None: FakeResp(json.dumps(payload).encode()))


def test_thinking_block_is_ignored(monkeypatch):
    mock_payload(monkeypatch, {
        "content": [{"type": "thinking", "thinking": "{\"fit\": \"x\"}"}, {"type": "text", "text": json.dumps(REPORT)}],
        "usage": {"input_tokens": 1, "output_tokens": 2}, "stop_reason": "end_turn",
    })
    assert api_provider().generate(SYSTEM, PROMPT).report == REPORT


def test_max_tokens_is_format_error_without_leak(monkeypatch, caplog):
    caplog.set_level(logging.DEBUG)
    mock_payload(monkeypatch, {
        "content": [{"type": "text", "text": PROMPT + '{"fit": "잘린'}],
        "usage": {"input_tokens": 100, "output_tokens": 8000}, "stop_reason": "max_tokens",
    })
    with pytest.raises(llm.ReportFormatError) as e:
        api_provider().generate(SYSTEM, PROMPT)
    assert e.value.usage.output_tokens == 8000 and e.value.usage.cost_krw > 0  # 비용 누적용
    assert PROMPT not in str(e.value) and PROMPT not in caplog.text and SECRET_KEY not in caplog.text


def test_refusal_is_call_error_without_leak(monkeypatch, caplog):
    caplog.set_level(logging.DEBUG)
    mock_payload(monkeypatch, {
        "content": [{"type": "text", "text": "거절문구-" + PROMPT}],
        "usage": {"input_tokens": 10, "output_tokens": 5}, "stop_reason": "refusal",
    })
    with pytest.raises(llm.ProviderCallError) as e:
        api_provider().generate(SYSTEM, PROMPT)
    assert "안전 판단" in str(e.value) and PROMPT not in str(e.value) and "거절문구" not in str(e.value)
    assert PROMPT not in caplog.text and "거절문구" not in caplog.text


# ---------- 재시도 ----------

class FakeTime:
    def __init__(self):
        self.now = 0.0
        self.sleeps = []

    def clock(self):
        return self.now

    def sleep(self, sec):
        self.sleeps.append(sec)
        self.now += sec


def retry_provider(ft, timeout=120):
    return llm.ApiProvider({"ANTHROPIC_API_KEY": SECRET_KEY}, timeout=timeout, sleep=ft.sleep, clock=ft.clock)


def sequence(monkeypatch, outcomes):
    """outcomes: (HTTP 코드, 헤더)·예외·응답 텍스트 순서. 마지막 항목은 계속 반복. 호출 때 받은 timeout 목록을 돌려준다."""
    calls = []

    def fake(req, timeout=None):
        calls.append(timeout)
        o = outcomes[min(len(calls) - 1, len(outcomes) - 1)]
        if isinstance(o, Exception):
            raise o
        if isinstance(o, tuple):
            code, headers = o
            raise urllib.error.HTTPError(req.full_url, code, "x " + SECRET_KEY, headers, io.BytesIO(PROMPT.encode()))
        body = {"content": [{"type": "text", "text": o}], "usage": {"input_tokens": 1, "output_tokens": 2}}
        return FakeResp(json.dumps(body).encode())

    monkeypatch.setattr(urllib.request, "urlopen", fake)
    return calls


OK = json.dumps(REPORT, ensure_ascii=False)


def test_429_retries_then_succeeds(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    ft = FakeTime()
    calls = sequence(monkeypatch, [(429, {}), OK])
    assert retry_provider(ft).generate(SYSTEM, PROMPT).report == REPORT
    assert len(calls) == 2 and ft.sleeps == [1.0]
    assert "retry" in caplog.text and PROMPT not in caplog.text and SECRET_KEY not in caplog.text


def test_529_twice_then_third_succeeds(monkeypatch):
    ft = FakeTime()
    calls = sequence(monkeypatch, [(529, {}), (529, {}), OK])
    assert retry_provider(ft).generate(SYSTEM, PROMPT).report == REPORT
    assert len(calls) == 3 and ft.sleeps == [1.0, 2.0]


def test_connection_error_is_retried(monkeypatch):
    ft = FakeTime()
    calls = sequence(monkeypatch, [urllib.error.URLError("down"), OK])
    assert retry_provider(ft).generate(SYSTEM, PROMPT).report == REPORT
    assert len(calls) == 2


def test_400_is_not_retried(monkeypatch):
    ft = FakeTime()
    calls = sequence(monkeypatch, [(400, {})])
    with pytest.raises(llm.ProviderCallError) as e:
        retry_provider(ft).generate(SYSTEM, PROMPT)
    assert len(calls) == 1 and ft.sleeps == []
    assert SECRET_KEY not in str(e.value) and PROMPT not in str(e.value)


def test_retry_after_is_capped_at_10_seconds(monkeypatch):
    ft = FakeTime()
    sequence(monkeypatch, [(429, {"Retry-After": "600"}), (429, {"retry-after": "3"}), OK])
    retry_provider(ft).generate(SYSTEM, PROMPT)
    assert ft.sleeps == [10.0, 3.0]


def test_never_more_than_three_attempts(monkeypatch):
    ft = FakeTime()
    calls = sequence(monkeypatch, [(500, {})])
    with pytest.raises(llm.ProviderCallError):
        retry_provider(ft).generate(SYSTEM, PROMPT)
    assert len(calls) == 3 and ft.sleeps == [1.0, 2.0]


def test_retry_respects_total_timeout(monkeypatch):
    ft = FakeTime()
    calls = sequence(monkeypatch, [(429, {"retry-after": "10"})])
    with pytest.raises(llm.ProviderCallError):
        retry_provider(ft, timeout=5).generate(SYSTEM, PROMPT)
    assert len(calls) == 1 and ft.sleeps == []  # 기다리면 제한을 넘으므로 더 시도하지 않음
    ft2 = FakeTime()
    calls = sequence(monkeypatch, [(500, {})])
    with pytest.raises(llm.ProviderCallError):
        retry_provider(ft2, timeout=2.5).generate(SYSTEM, PROMPT)
    assert ft2.now <= 2.5 and all(t <= 2.5 for t in calls)


# ---------- Cloud Run에서 fake ----------

def test_fake_on_cloud_run_is_not_ready_but_startup_allowed():
    env = {"GWITTIM_LLM_PROVIDER": "fake", "K_SERVICE": "gwittim-api"}
    assert llm.check_startup(env) == "fake"  # 시작은 막지 않는다
    with pytest.raises(llm.ProviderNotReady):
        llm.get_provider(env=env).generate(SYSTEM, PROMPT)
    assert llm.get_provider("fake", env={}).generate(SYSTEM, PROMPT).report == llm.FAKE_REPORT


# ---------- deepseek (D-044) ----------

DS_KEY = "sk-ds-test-SECRET-5678"


def ds_provider(**kw):
    return llm.DeepSeekProvider(env={"DEEPSEEK_API_KEY": DS_KEY}, **kw)


def mock_ds(monkeypatch, content, seen=None, finish="stop", usage=None):
    def fake(req, timeout=None):
        if seen is not None:
            seen["req"] = req
        body = {
            "choices": [{"message": {"role": "assistant", "content": content, "reasoning_content": "생각-원문"},
                         "finish_reason": finish}],
            "usage": usage if usage is not None else {"prompt_tokens": 3000, "completion_tokens": 1500},
        }
        return FakeResp(json.dumps(body, ensure_ascii=False).encode())

    monkeypatch.setattr(urllib.request, "urlopen", fake)


def test_deepseek_selected_by_env():
    p = llm.get_provider(env={"GWITTIM_LLM_PROVIDER": "deepseek"})
    assert isinstance(p, llm.DeepSeekProvider) and p.name == "deepseek"


def test_deepseek_without_key_is_not_ready(monkeypatch):
    def boom(*a, **k):
        raise AssertionError("키 없이 호출함")

    monkeypatch.setattr(urllib.request, "urlopen", boom)
    with pytest.raises(llm.ProviderNotReady):
        llm.DeepSeekProvider(env={}).generate(SYSTEM, PROMPT)


def test_deepseek_request_body_and_headers(monkeypatch):
    seen = {}
    mock_ds(monkeypatch, json.dumps(REPORT, ensure_ascii=False), seen)
    res = ds_provider().generate(SYSTEM, PROMPT)
    assert res.report == REPORT
    req = seen["req"]
    assert req.full_url == "https://api.deepseek.com/chat/completions"
    headers = {k.lower(): v for k, v in req.header_items()}
    assert headers["authorization"] == f"Bearer {DS_KEY}"
    sent = json.loads(req.data)
    assert sent["model"] == "deepseek-flash"
    assert sent["messages"] == [{"role": "system", "content": SYSTEM}, {"role": "user", "content": PROMPT}]
    assert sent["response_format"] == {"type": "json_object"}
    assert sent["reasoning_effort"] == "none"
    assert sent["max_tokens"] == 8000
    assert "tools" not in sent  # 상세 분석에는 웹 검색을 붙이지 않는다


def test_deepseek_reasoning_content_is_dropped(monkeypatch):
    mock_ds(monkeypatch, json.dumps(REPORT, ensure_ascii=False))
    res = ds_provider().generate(SYSTEM, PROMPT)
    assert "생각-원문" not in json.dumps(res.report, ensure_ascii=False)


def test_deepseek_blank_content_is_format_error_with_usage(monkeypatch):
    mock_ds(monkeypatch, "   ")  # JSON으로 인식 못 한 출력은 공백으로 온다
    with pytest.raises(llm.ReportFormatError) as ei:
        ds_provider().generate(SYSTEM, PROMPT)
    assert ei.value.usage is not None and ei.value.usage.output_tokens == 1500


def test_deepseek_length_is_format_error(monkeypatch):
    mock_ds(monkeypatch, '{"fit": "잘', finish="length")
    with pytest.raises(llm.ReportFormatError):
        ds_provider().generate(SYSTEM, PROMPT)


def test_deepseek_content_filter_is_call_error(monkeypatch):
    mock_ds(monkeypatch, "", finish="content_filter")
    with pytest.raises(llm.ProviderCallError):
        ds_provider().generate(SYSTEM, PROMPT)


@pytest.mark.parametrize("code", [401, 402])
def test_deepseek_auth_and_balance_errors_not_retried_no_secret(monkeypatch, caplog, code):
    calls = []

    def fake(req, timeout=None):
        calls.append(1)
        raise urllib.error.HTTPError(req.full_url, code, "err", {}, io.BytesIO(DS_KEY.encode()))

    monkeypatch.setattr(urllib.request, "urlopen", fake)
    caplog.set_level(logging.INFO, logger="gwittim.agent.llm")
    with pytest.raises(llm.ProviderCallError) as ei:
        ds_provider(sleep=lambda s: None).generate(SYSTEM, PROMPT)
    assert len(calls) == 1
    assert DS_KEY not in str(ei.value) and DS_KEY not in caplog.text and PROMPT not in caplog.text


def test_deepseek_429_is_retried(monkeypatch):
    calls = []

    def fake(req, timeout=None):
        calls.append(1)
        if len(calls) == 1:
            raise urllib.error.HTTPError(req.full_url, 429, "busy", {}, None)
        body = {"choices": [{"message": {"content": json.dumps(REPORT)}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1}}
        return FakeResp(json.dumps(body).encode())

    monkeypatch.setattr(urllib.request, "urlopen", fake)
    assert ds_provider(sleep=lambda s: None).generate(SYSTEM, PROMPT).report == REPORT
    assert len(calls) == 2


def test_deepseek_prices_peak_and_off_peak():
    from datetime import datetime, timezone
    assert llm.deepseek_prices(datetime(2026, 11, 23, 2, 0, tzinfo=timezone.utc)) == (0.30, 1.20)  # 월 11시 KST
    assert llm.deepseek_prices(datetime(2026, 11, 23, 5, 0, tzinfo=timezone.utc)) == (0.15, 0.60)  # 월 14시 KST
    assert llm.deepseek_prices(datetime(2026, 11, 23, 9, 59, tzinfo=timezone.utc)) == (0.30, 1.20)
    assert llm.deepseek_prices(datetime(2026, 11, 23, 10, 0, tzinfo=timezone.utc)) == (0.15, 0.60)
    assert llm.deepseek_prices(datetime(2026, 11, 22, 2, 0, tzinfo=timezone.utc)) == (0.15, 0.60)  # 일요일


def test_deepseek_cost_uses_its_own_price(monkeypatch):
    mock_ds(monkeypatch, json.dumps(REPORT))
    monkeypatch.setattr(llm, "deepseek_prices", lambda at: (0.15, 0.60))
    res = ds_provider().generate(SYSTEM, PROMPT)
    # 3000*0.15 + 1500*0.60 = 1350 USD/1e6 -> 1.89원
    assert res.usage.cost_krw == 1.89


def test_system_prompt_mentions_json_example():
    from backend.agent.prompt import SYSTEM_PROMPT
    assert "json" in SYSTEM_PROMPT and '"fit"' in SYSTEM_PROMPT
