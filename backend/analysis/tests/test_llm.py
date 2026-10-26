"""가짜 Ollama 서버로 LLM 분석기의 검증 경계를 확인한다. 실제 모델·Ollama 설치 불필요."""
import json
import threading
from datetime import date
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

from backend.analysis import build_notice
from backend.analysis.llm import OllamaAnalyzer, redact
from backend.collectors.common import InMemoryStore, content_hash, ingest
from backend.contracts import schema_errors
from backend.sources import source_config

ROOT = Path(__file__).resolve().parents[3]
MJC = source_config("mjc_www_notice")

BODY = (
    "취업 역량 강화 특강 참가자 모집\n"
    "대상: 컴퓨터공학과 학생\n"
    "접수는 2026.11.05.(목) 17:00까지 이메일로 제출\n"
    "문의: 합성팀 02-300-1234, test@example.invalid\n"
    "토익 700점 이상 우대\n"
)


class FakeOllama:
    def __init__(self):
        self.reply: dict | str = {}
        self.requests: list[dict] = []
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                fake.requests.append(body)
                if fake.reply == "error":
                    self.send_response(500)
                    self.end_headers()
                    return
                content = json.dumps(fake.reply, ensure_ascii=False)
                data = json.dumps({"message": {"role": "assistant", "content": content}}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *a):
                pass

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"


@pytest.fixture
def ollama():
    fake = FakeOllama()
    yield fake
    fake.server.shutdown()


def raw(body=BODY, attachments=None):
    r = json.loads((ROOT / "fixtures/valid/raw_notice/mjc_board_date_only.json").read_text(encoding="utf-8"))
    r.update(title="[합성 샘플] 취업 특강", body_text=body, attachments=attachments or [])
    r["content_hash"] = content_hash(r)
    return r


def analyzer(fake):
    return OllamaAnalyzer("test-model", host=fake.url, timeout=5)


def test_prompt_redacts_contacts_and_uses_json_schema(ollama):
    ollama.reply = {"summary": None, "deadline": None, "conditions": [], "unresolved": []}
    analyzer(ollama).analyze(raw(), MJC)
    req = ollama.requests[0]
    prompt = req["messages"][1]["content"]
    assert "test@example.invalid" not in prompt and "02-300-1234" not in prompt
    assert req["format"]["type"] == "object" and req["options"]["temperature"] == 0
    assert req["think"] is False
    assert redact("010-1234-5678 a@b.co") == "[전화번호 생략] [이메일 생략]"


def test_grounded_llm_output_is_merged(ollama):
    ollama.reply = {
        "summary": "컴퓨터공학과 학생 대상 취업 특강이며 11월 5일 17시까지 접수한다.",
        "deadline": None,  # 규칙이 이미 찾음
        "conditions": [{"field": "major_id", "operator": "eq", "value": "mjc.computer_engineering", "evidence": "대상: 컴퓨터공학과 학생"}],
        "unresolved": ["토익 700점 이상 우대"],
    }
    a = analyzer(ollama)
    fields = a.analyze(raw(), MJC)
    assert fields["application_deadline"]["date"] == "2026-11-05"  # 결정적 파싱 결과 유지
    conds = {c["field"]: c["value"] for c in fields["eligibility"]["conditions"]}
    assert conds["major_id"] == "mjc.computer_engineering"
    assert fields["eligibility"]["extraction_complete"] is False  # 우대 조건 → 미완성
    assert fields["summary"].startswith("컴퓨터공학과")
    assert "_analysis_version" not in fields and a.version == "rule-0.4+ollama:test-model"


def test_hallucinations_are_rejected(ollama):
    ollama.reply = {
        "summary": "12월 31일까지 신청하면 100만원을 준다.",  # 원문에 없는 숫자
        "deadline": {"evidence": "2026.12.31.까지 신청"},  # 원문에 없는 근거
        "conditions": [
            {"field": "grade", "operator": "in", "value": [2, 3], "evidence": "2~3학년 대상"},  # 근거 없음
            {"field": "major_id", "operator": "eq", "value": "mjc.no_such", "evidence": "대상: 컴퓨터공학과 학생"},  # 사전에 없음
            {"field": "income", "operator": "eq", "value": 1, "evidence": "대상: 컴퓨터공학과 학생"},  # 지원 안 하는 필드
        ],
        "unresolved": ["원문에 없는 조건"],
    }
    a = analyzer(ollama)
    fields = a.analyze(raw(body="특강 안내\n대상: 컴퓨터공학과 학생"), MJC)
    assert fields["summary"] is None
    assert fields["application_deadline"] is None
    # 학과 조건은 규칙 분석이 원문에서 직접 찾은 것만 남고, LLM의 가짜 값·근거 없는 학년은 버린다
    assert [(c["field"], c["value"]) for c in fields["eligibility"]["conditions"]] == [("major_id", "mjc.computer_engineering")]
    assert fields["eligibility"]["unresolved_conditions"] == []
    assert len(a.rejected) >= 4


def test_llm_fills_deadline_only_when_rules_missed(ollama):
    body = "특강 안내\n늦어도 2026년 11월 9일 17시 30분 전까지 신청 바랍니다"  # 규칙 키워드 없음
    ollama.reply = {"summary": None, "deadline": {"evidence": "늦어도 2026년 11월 9일 17시 30분 전까지 신청 바랍니다"}, "conditions": [], "unresolved": []}
    fields = analyzer(ollama).analyze(raw(body=body), MJC)
    d = fields["application_deadline"]
    assert (d["date"], d["time"], d["timezone"]) == ("2026-11-09", "17:30", "Asia/Seoul")


def test_llm_never_marks_extraction_complete(ollama):
    ollama.reply = {"summary": None, "deadline": None, "conditions": [], "unresolved": []}
    attach = [{"file_name": "요강.hwp", "url": None, "type": "hwp"}]
    fields = analyzer(ollama).analyze(raw(attachments=attach), MJC)
    assert fields["eligibility"]["extraction_complete"] is False


def test_ollama_failure_falls_back_to_rule_version(ollama):
    ollama.reply = "error"
    store = InMemoryStore()
    result = ingest(raw(), store)
    notice, issues = build_notice(store.records[result.key], today=date(2026, 10, 17), analyzer=analyzer(ollama))
    assert notice["analysis_version"] == "rule-0.4"
    assert issues == [] and schema_errors("notice", notice) == []


def test_llm_notice_passes_validation(ollama):
    ollama.reply = {
        "summary": None,
        "deadline": None,
        "conditions": [{"field": "major_id", "operator": "eq", "value": "mjc.computer_engineering", "evidence": "대상: 컴퓨터공학과 학생"}],
        "unresolved": [],
    }
    store = InMemoryStore()
    result = ingest(raw(), store)
    notice, issues = build_notice(store.records[result.key], today=date(2026, 10, 17), analyzer=analyzer(ollama))
    assert issues == []
    assert notice["analysis_version"] == "rule-0.4+ollama:test-model"


def test_summary_with_wrong_weekday_or_unknown_date_is_rejected(ollama):
    body = "접수기한 : 2026.10.30.(금) 까지\n본선 : 2026.11.13.(금) 15:00"
    a = analyzer(ollama)
    ollama.reply = {"summary": "10월 30일(화)까지 접수한다.", "deadline": None, "conditions": [], "unresolved": []}
    assert a.analyze(raw(body=body), MJC)["summary"] is None  # 10/30은 금요일
    ollama.reply = {"summary": "10월 13일까지 접수한다.", "deadline": None, "conditions": [], "unresolved": []}
    assert a.analyze(raw(body=body), MJC)["summary"] is None  # 원문에 없는 날짜 (숫자 10·13은 원문에 있음)
    ollama.reply = {"summary": "10월 30일(금)까지 접수하고 11월 13일 본선을 연다.", "deadline": None, "conditions": [], "unresolved": []}
    assert a.analyze(raw(body=body), MJC)["summary"] == "10월 30일(금)까지 접수하고 11월 13일 본선을 연다."
    ollama.reply = {"summary": "모집은 11월 30일까지다.", "deadline": None, "conditions": [], "unresolved": []}
    body2 = "모집기간 ; 2026.10.14 ~ 2026.11.30"  # 요일 없는 날짜도 원문 날짜로 인정
    assert a.analyze(raw(body=body2), MJC)["summary"] == "모집은 11월 30일까지다."
    ollama.reply = {"summary": "2026 년 12 월 말까지 모집합니다.", "deadline": None, "conditions": [], "unresolved": []}
    assert a.analyze(raw(body=body2), MJC)["summary"] is None  # 원문에 없는 '12월 말'
