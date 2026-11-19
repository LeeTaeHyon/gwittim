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
