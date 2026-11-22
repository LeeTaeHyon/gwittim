"""외부 LLM 후보를 게시판 공고로 비교한다 (D-039 맞춤 에이전트 모델 고르기).

API 키 대신 개인 구독 CLI로 돌린다(테스트 전용, 앱 서버에는 쓰지 않음).
  - Claude: Claude Code `claude -p` (구독 로그인)
  - GPT:    Codex `codex exec` (ChatGPT 로그인)
모든 모델에 같은 지시문·같은 JSON 양식을 준다. 차이: CLI가 자기 기본 지시문을 덧붙이고(Codex는 끌 수 없음),
그래서 입력 토큰에 CLI 몫이 섞인다. 비용은 모델마다 짧은 기준 호출의 입력 토큰을 빼서 공고 몫만 추정한다.

자료는 data/local/llm_compare/ 에만 둔다(git 제외). 정답은 사람이 채운다(모델로 채우지 않음).

하위 명령
  select   게시판 정답표 표본(board_sheet_A.csv)에서 20건을 고르고, 빈 정답표 gold_20.csv를 만든다
  run      모델 하나로 20건 추출 (--model 이름, MODELS 표 참고)
  report   공고 5건으로 고정 프로필 맞춤 리포트를 만든다(모델별)
  blind    리포트를 모델 이름 없이 A~D로 섞은 blind_report.md와 정답 열쇠를 만든다
  score    근거 원문 존재율, 비용·시간, 정답표가 채워졌으면 마감일·조건·판정 채점

실행 예: C:\\Python314\\python.exe tools/llm_compare.py run --model haiku
  표준 라이브러리만 쓰므로 시스템 파이썬으로 돌린다. `uv run`(.venv 파이썬) 아래에서는 Codex가
  'failed to initialize in-process app-server client: 액세스가 거부되었습니다'로 실패한다(2026-11-16 확인).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from backend.recommendation.eligibility import evaluate  # noqa: E402
from tools.board_gold_common import (  # noqa: E402
    BOARDS, GOLD_DIR, NOTICES, dictionary_codes, load_notices, read_sheet, validate_rows, write_sheet,
)
from tools.eval_board_extraction import evaluate_all, normalize, render  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "data/local/llm_compare"
RECORDS = ROOT / "data/local/pipeline/records.json"
SAMPLE = OUT / "sample.json"
GOLD = OUT / "gold_20.csv"
KRW_PER_USD = 1400

# 이름 -> (CLI, 모델 id, 입력·출력 USD/MTok, 가격 출처)
MODELS = {
    "haiku": ("claude", "claude-haiku-5-5", 0.10, 0.50, "Anthropic 공식"),
    "sonnet": ("claude", "claude-sonnet-5-5", 2.00, 10.00, "Anthropic 공식"),
    "luna": ("codex", "gpt-6-luna", 0.10, 0.50, "제3자 정리 사이트(미확인)"),
    "sol": ("codex", "gpt-6.1-sol", 2.00, 10.00, "제3자 정리 사이트(미확인)"),
    "terra": ("codex", "gpt-6.1-terra", 1.00, 5.00, "제3자 정리 사이트(미확인)"),
    # opencode run은 출력 스키마 강제가 없어 지시문 끝에 스키마를 붙이고 JSON을 직접 파싱한다.
    "dsflash": ("opencode", "opencode-go/deepseek-v4.1-flash", 0.30, 1.20, "2차 보도·정리 사이트, DeepSeek 피크 요금(미확인)"),
    # Gemini는 구독 CLI 로그인이 막혀(2026-11-16) 무료 등급 API 키(.env GEMINI_API_KEY)로 부른다. 유료 가격 미확인.
    "hydrogen": ("gemini_api", "gemini-4-hydrogen", None, None, "가격 미확인(무료 등급으로 실행)"),
    # 로컬 Ollama. 외부 요금 없음(전기·장비 비용 제외). 자동 수집 분석기와 같은 모델이지만 여기서는 같은 지시문으로 단독 비교한다.
    "gemma": ("ollama", "gemma4:12b", 0.0, 0.0, "로컬 실행"),
}
GEMINI_GAP_SECONDS = 13  # 무료 등급 분당 5회
EFFORT = "medium"
QUOTA = {"공지": 6, "채용": 5, "장학": 5, "근로": 4}
REPORT_PROFILE = {
    "학교": "명지전문대학", "학과": "컴퓨터공학과", "학년": 2, "재학 상태": "재학",
    "관심 분야": ["AI·데이터", "IT·개발"], "희망 직무": ["소프트웨어 개발"],
}
REPORT_PROFILE_CODES = {"university_id": "mjc", "major_id": "mjc.computer_engineering", "grade": 2, "enrollment_status": "enrolled"}


def extraction_schema() -> dict:
    codes = dictionary_codes()
    nullable_str = {"type": ["string", "null"]}
    return {
        "type": "object",
        "additionalProperties": False,
        "required": ["deadline", "everyone", "conditions", "other_conditions", "summary", "required_skills"],
        "properties": {
            "deadline": {
                "type": "object", "additionalProperties": False, "required": ["date", "evidence"],
                "properties": {"date": nullable_str, "evidence": nullable_str},
            },
            "everyone": {"type": "boolean"},
            "conditions": {
                "type": "array",
                "items": {
                    "type": "object", "additionalProperties": False, "required": ["field", "values", "evidence"],
                    "properties": {
                        "field": {"type": "string", "enum": ["university_id", "major_id", "grade", "enrollment_status"]},
                        "values": {"type": "array", "items": {"type": "string", "enum": sorted(set(sum(codes.values(), [])))}},
                        "evidence": {"type": "string"},
                    },
                },
            },
            "other_conditions": {
                "type": "array",
                "items": {
                    "type": "object", "additionalProperties": False, "required": ["kind", "evidence"],
                    "properties": {"kind": {"type": "string", "enum": ["자격", "우대"]}, "evidence": {"type": "string"}},
                },
            },
            "summary": {"type": "string"},
            "required_skills": {
                "type": "array",
                "items": {
                    "type": "object", "additionalProperties": False, "required": ["skill", "evidence"],
                    "properties": {"skill": {"type": "string"}, "evidence": {"type": "string"}},
                },
            },
        },
    }


def extraction_prompt(n: dict) -> str:
    codes = dictionary_codes()
    majors = " ".join(codes["학과"])
    return f"""아래 학교 공지 원문을 읽고 JSON 양식대로 채운다. 원문에 없는 것은 지어내지 않는다.

규칙
- evidence는 원문에서 그대로 복사한 연속된 문구다. 고치거나 요약하지 않는다.
- deadline.date: 지원 마감일 YYYY-MM-DD. 원문에 마감일이 없거나 확정할 수 없으면 null. 시각은 적지 않는다.
  연도가 없으면 게시일({n['published']}) 기준으로 가장 가까운 미래 날짜로 본다.
- everyone: 원문이 누구나(재학생 누구나 등) 지원 가능하다고 하고 다른 제한이 없으면 true.
- conditions: 지원 자격으로 명시된 학교·학과·학년·재학상태만. 값은 코드로 적고, 여러 개면 그중 하나면 지원 가능이다.
  학교 mjc / 학년 1 2 3 4 / 재학상태 enrolled(재학) on_leave(휴학) graduated(졸업·졸업예정)
  학과: {majors}
- other_conditions: 위 코드로 적을 수 없는 자격(성적·소득·어학·연령·거주지 등)은 kind "자격", 우대 사항은 "우대". 한 조건에 하나.
- summary: 한국어 2문장, 합쇼체.
- required_skills: 공고가 요구하거나 우대하는 기술·역량. 원문 근거가 없으면 넣지 않는다.

제목: {n['title']}
게시판: {n['board']}
게시일: {n['published']}
원문:
{n['body_text']}"""


REPORT_SECTIONS = {"eligibility": "지원 자격", "skills": "필요한 역량", "fit": "이 학생에게 맞는 점", "todo": "지원 전 할 일"}


def report_schema() -> dict:
    """v2 리포트: 형식은 앱이 그리고 모델은 내용만 채운다(모델별 마크다운 습관 차이를 없앰)."""
    items = {"type": "array", "items": {"type": "string"}}
    return {"type": "object", "additionalProperties": False,
            "required": ["summary", *REPORT_SECTIONS],
            "properties": {"summary": {"type": "string"}, **{k: items for k in REPORT_SECTIONS}}}


def report_prompt(n: dict, judgement: str, results: list[dict], structured: bool = False) -> str:
    profile = json.dumps(REPORT_PROFILE, ensure_ascii=False)
    lines = "\n".join(f"- {r['field']}: {r['status']} (근거: {r['evidence']})" for r in results) or "- (구조 조건 없음)"
    head = ("학생 한 명을 위해 아래 공고의 맞춤 리포트를 JSON 양식대로 채운다. 합쇼체.\n"
            "summary는 한 문장. eligibility(지원 자격, 시스템 판정 설명)·skills(필요한 역량)·fit(이 학생에게 맞는 점)·"
            "todo(지원 전 할 일)는 항목 2~5개, 항목마다 한두 문장. 마크다운 기호는 쓰지 않는다."
            if structured else "학생 한 명을 위해 아래 공고의 맞춤 리포트를 한국어 마크다운으로 쓴다. 600자 안팎, 합쇼체.")
    return f"""{head}

지킬 것
- 지원 자격 판정은 아래 '시스템 판정'을 그대로 따른다. 다르게 말하지 않는다. 합격 가능성은 말하지 않는다.
- 필요한 기술·역량은 공고에 적힌 것만, 근거 문구와 함께. 학생의 보유 기술은 모르므로 추정하지 않는다.
- 원문에 없는 날짜·조건·혜택을 지어내지 않는다. 모르는 것은 '공고 원문 확인 필요'라고 쓴다.

구성: 한 줄 요약 / 지원 자격(시스템 판정 설명) / 필요한 역량 / 이 학생에게 맞는 점 / 지원 전 할 일

학생 프로필: {profile}
시스템 판정: {judgement}
조건별 결과:
{lines}

제목: {n['title']}
게시일: {n['published']}
원문:
{n['body_text']}"""


# ---------- 실행 ----------

def call_claude(model: str, prompt: str, schema: dict | None, workdir: Path) -> dict:
    cmd = [shutil.which("claude") or "claude", "-p", "--model", model, "--tools", "",
           "--system-prompt", "주어진 지시를 따른다.", "--output-format", "json", "--effort", EFFORT]
    if schema is not None:
        cmd += ["--json-schema", json.dumps(schema, ensure_ascii=False)]
    t0 = time.monotonic()
    p = subprocess.run(cmd, input=prompt, capture_output=True, text=True, encoding="utf-8", cwd=workdir, timeout=600)
    wall = time.monotonic() - t0
    j = json.loads(p.stdout)
    u = j["usage"]
    tokens_in = u["input_tokens"] + u.get("cache_creation_input_tokens", 0) + u.get("cache_read_input_tokens", 0)
    out = j.get("structured_output") if schema is not None else j.get("result")
    return {"ok": not j.get("is_error") and out is not None, "output": out, "error": None if not j.get("is_error") else j.get("result"),
            "tokens_in": tokens_in, "tokens_out": u["output_tokens"], "seconds": round(wall, 1)}


def call_codex(model: str, prompt: str, schema: dict | None, workdir: Path) -> dict:
    cmd = [shutil.which("codex") or "codex", "exec", "-m", model, "--skip-git-repo-check", "-s", "read-only",
           "--json", "-c", f'model_reasoning_effort="{EFFORT}"']
    if schema is not None:
        sf = workdir / "schema.json"
        sf.write_text(json.dumps(schema, ensure_ascii=False), encoding="utf-8")
        cmd += ["--output-schema", str(sf)]
    cmd.append("-")  # 지시문은 표준 입력으로
    t0 = time.monotonic()
    p = subprocess.run(cmd, input=prompt, capture_output=True, text=True, encoding="utf-8", cwd=workdir, timeout=600)
    wall = time.monotonic() - t0
    text, usage, err = None, None, None
    for line in p.stdout.splitlines():
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("type") == "item.completed" and ev["item"].get("type") == "agent_message":
            text = ev["item"]["text"]
        elif ev.get("type") == "turn.completed":
            usage = ev["usage"]
        elif ev.get("type") == "turn.failed":
            err = json.dumps(ev, ensure_ascii=False)
    out = None
    if text is not None:
        out = json.loads(text) if schema is not None else text
    return {"ok": out is not None and usage is not None, "output": out, "error": err or (None if out is not None else p.stderr[-500:]),
            "tokens_in": (usage or {}).get("input_tokens", 0),
            "tokens_out": (usage or {}).get("output_tokens", 0) + (usage or {}).get("reasoning_output_tokens", 0),
            "seconds": round(wall, 1)}


def _parse_json(text: str):
    t = text.strip()
    a, b = t.find("{"), t.rfind("}")
    return json.loads(t[a:b + 1] if a >= 0 and b > a else t)


def call_opencode(model: str, prompt: str, schema: dict | None, workdir: Path) -> dict:
    if schema is not None:
        prompt += ("\n\n출력 형식: 아래 JSON Schema를 지키는 JSON 객체 하나만 출력한다. 코드 블록·설명 없이.\n"
                   + json.dumps(schema, ensure_ascii=False))
    cmd = [shutil.which("opencode") or "opencode", "run", "-m", model, "--format", "json", "--pure"]
    t0 = time.monotonic()
    p = subprocess.run(cmd, input=prompt, capture_output=True, text=True, encoding="utf-8", cwd=workdir, timeout=600)
    wall = time.monotonic() - t0
    texts, tin, tout, err = [], 0, 0, None
    for line in p.stdout.splitlines():
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        part = ev.get("part") or {}
        if ev.get("type") == "text":
            texts.append(part.get("text", ""))
        elif ev.get("type") == "step_finish":
            tok = part.get("tokens") or {}
            tin += tok.get("input", 0) + (tok.get("cache") or {}).get("read", 0)
            tout += tok.get("output", 0) + tok.get("reasoning", 0)
        elif ev.get("type") == "error":
            err = json.dumps(ev, ensure_ascii=False)[:1000]
    text = "".join(texts)
    out = None
    if text:
        try:
            out = _parse_json(text) if schema is not None else text
        except json.JSONDecodeError as e:
            err = f"JSON 파싱 실패: {e}: {text[:300]}"
    return {"ok": out is not None and tin > 0, "output": out, "error": err or (None if out is not None else p.stderr[-500:]),
            "tokens_in": tin, "tokens_out": tout, "seconds": round(wall, 1)}


def _env(key: str) -> str | None:
    path = ROOT / ".env"
    if not path.exists():
        return None
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            if k.strip() == key:
                return v.strip().strip('"').strip("'")
    return None


_last_gemini = 0.0


def call_gemini(model: str, prompt: str, schema: dict | None) -> dict:
    """Gemini API 직접 호출(키는 .env에서만 읽고 출력하지 않는다)."""
    import urllib.error
    import urllib.request

    global _last_gemini
    wait = GEMINI_GAP_SECONDS - (time.monotonic() - _last_gemini)
    if wait > 0:
        time.sleep(wait)
    body = {"contents": [{"role": "user", "parts": [{"text": prompt}]}], "generationConfig": {}}
    if schema is not None:
        body["generationConfig"] = {"responseMimeType": "application/json", "responseJsonSchema": schema}
    req = urllib.request.Request(
        f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json", "x-goog-api-key": _env("GEMINI_API_KEY") or ""},
    )
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            j = json.load(r)
        err = None
    except urllib.error.HTTPError as e:
        j, err = {}, f"HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:1500]}"
    _last_gemini = time.monotonic()
    wall = time.monotonic() - t0
    text = None
    try:
        text = "".join(p.get("text", "") for p in j["candidates"][0]["content"]["parts"] if not p.get("thought"))
    except (KeyError, IndexError):
        err = err or json.dumps(j, ensure_ascii=False)[:300]
    out = None
    if text:
        try:
            out = json.loads(text) if schema is not None else text
        except json.JSONDecodeError:
            err = "JSON 아님: " + text[:200]
    u = j.get("usageMetadata", {})
    return {"ok": out is not None, "output": out, "error": err,
            "tokens_in": u.get("promptTokenCount", 0),
            "tokens_out": u.get("candidatesTokenCount", 0) + u.get("thoughtsTokenCount", 0),
            "seconds": round(wall, 1)}


def call_ollama(model: str, prompt: str, schema: dict | None) -> dict:
    """로컬 Ollama 호출. 배치 분석기(backend/analysis/llm.py)처럼 think 끔, temperature 0."""
    import urllib.request

    body = {"model": model, "stream": False, "think": False,
            "options": {"temperature": 0, "num_ctx": 16384},  # 기본 문맥이 짧아 긴 공고가 잘리지 않게
            "messages": [{"role": "user", "content": prompt}]}
    if schema is not None:
        body["format"] = schema
    req = urllib.request.Request("http://localhost:11434/api/chat", data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    err, out, j = None, None, {}
    try:
        with urllib.request.urlopen(req, timeout=900) as r:
            j = json.load(r)
        text = j.get("message", {}).get("content", "")
        out = json.loads(text) if schema is not None else text
    except Exception as e:  # noqa: BLE001 - 비교 기록용
        err = f"{type(e).__name__}: {str(e)[:300]}"
    return {"ok": out is not None, "output": out, "error": err,
            "tokens_in": j.get("prompt_eval_count", 0), "tokens_out": j.get("eval_count", 0),
            "seconds": round(time.monotonic() - t0, 1)}


def call(name: str, prompt: str, schema: dict | None) -> dict:
    cli, model_id, *_ = MODELS[name]
    if cli == "ollama":
        return call_ollama(model_id, prompt, schema)
    if cli == "gemini_api":
        return call_gemini(model_id, prompt, schema)
    with tempfile.TemporaryDirectory() as d:  # 빈 폴더에서 돌려 저장소 파일·지시문이 끼지 않게
        fn = {"claude": call_claude, "codex": call_codex, "opencode": call_opencode}[cli]
        return fn(model_id, prompt, schema, Path(d))


def baseline(name: str) -> int:
    """CLI가 덧붙이는 입력 토큰(짧은 기준 호출 2번의 중앙값)."""
    schema = {"type": "object", "additionalProperties": False, "required": ["answer"], "properties": {"answer": {"type": "string"}}}
    vals = [call(name, "answer에 ok를 적는다.", schema)["tokens_in"] for _ in range(2)]
    return int(statistics.median(vals))


# ---------- 하위 명령 ----------

def cmd_select(args) -> None:
    rows = read_sheet(GOLD_DIR / "board_sheet_A.csv")
    records = json.loads(RECORDS.read_text(encoding="utf-8"))
    notices = load_notices(NOTICES)
    pool: dict[str, list] = {b: [] for b in QUOTA}
    for r in rows:
        rec = records.get(r["notice_id"])
        body = (rec or {}).get("raw", {}).get("body_text") or ""
        if not 200 <= len(body) <= 8000 or r["notice_id"] not in notices:
            continue
        el = notices[r["notice_id"]]["eligibility"]
        richness = len(el["conditions"]) + len(el["unresolved_conditions"])
        pool[r["게시판"]].append((r, rec["raw"], richness))
    rng = random.Random(1116)
    chosen = []
    for board, k in QUOTA.items():
        items = sorted(pool[board], key=lambda x: hashlib.sha256(x[0]["notice_id"].encode()).hexdigest())
        rng.shuffle(items)
        rich = [x for x in items if x[2] >= 2]
        plain = [x for x in items if x[2] < 2]
        take = rich[: (k + 1) // 2] + plain[: k // 2]  # 조건 많은 공고 절반 이상
        take += [x for x in items if x not in take][: k - len(take)]
        chosen += take[:k]
    sample = [{
        "notice_id": r["notice_id"], "board": r["게시판"], "title": raw["title"], "source_url": raw["source_url"],
        "published": (raw.get("published") or {}).get("date") or "", "body_text": raw["body_text"],
    } for r, raw, _ in chosen]
    OUT.mkdir(parents=True, exist_ok=True)
    SAMPLE.write_text(json.dumps(sample, ensure_ascii=False, indent=1), encoding="utf-8")
    if GOLD.exists() and not args.force:
        print(f"{GOLD} 가 이미 있어 그대로 둔다(--force로 다시 만듦)")
    else:
        write_sheet(GOLD, [r for r, _, _ in chosen])
    per = {b: sum(1 for s in sample if s["board"] == b) for b in QUOTA}
    print(f"{len(sample)}건 선택 {per} -> {SAMPLE}\n빈 정답표 -> {GOLD} (작성 안내: {GOLD_DIR / 'board_guide.txt'})")


def cmd_run(args) -> None:
    sample = json.loads(SAMPLE.read_text(encoding="utf-8"))
    run_dir = OUT / "runs" / args.model
    run_dir.mkdir(parents=True, exist_ok=True)
    meta = run_dir / "_baseline.json"
    if not meta.exists():
        meta.write_text(json.dumps({"tokens_in": baseline(args.model)}), encoding="utf-8")
    schema = extraction_schema()
    for i, n in enumerate(sample[: args.limit] if args.limit else sample, 1):
        path = run_dir / f"{n['notice_id'].replace(':', '_')}.json"
        if path.exists() and not args.force:
            continue
        try:
            res = call(args.model, extraction_prompt(n), schema)
        except Exception as e:  # 한 건 실패로 전체를 멈추지 않는다
            res = {"ok": False, "output": None, "error": repr(e)[:500], "tokens_in": 0, "tokens_out": 0, "seconds": None}
        path.write_text(json.dumps({"notice_id": n["notice_id"], **res}, ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"[{args.model}] {i}/{len(sample)} {n['notice_id']} {'ok' if res['ok'] else '실패'} {res['seconds']}s")


def cmd_report(args) -> None:
    full = json.loads(SAMPLE.read_text(encoding="utf-8"))
    sample = full[:: max(1, len(full) // 5)][:5]  # 게시판이 고루 섞이도록 띄엄띄엄 5건
    notices = load_notices(NOTICES)
    run_dir = OUT / ("reports_v2" if args.v2 else "reports") / args.model
    run_dir.mkdir(parents=True, exist_ok=True)
    for n in sample:
        path = run_dir / f"{n['notice_id'].replace(':', '_')}.json"
        if path.exists() and not args.force:
            continue
        judgement, results = evaluate(notices[n["notice_id"]]["eligibility"], REPORT_PROFILE_CODES)
        res = call(args.model, report_prompt(n, judgement, results, args.v2), report_schema() if args.v2 else None)
        path.write_text(json.dumps({"notice_id": n["notice_id"], "judgement": judgement, **res}, ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"[{args.model}] 리포트 {n['notice_id']} {'ok' if res['ok'] else '실패'} {res['seconds']}s")


def cmd_blind(args) -> None:
    rep = OUT / "reports"
    models = sorted(p.name for p in rep.iterdir() if p.is_dir())
    ids = sorted({f.stem for m in models for f in (rep / m).glob("*.json")})
    rng = random.Random(args.seed)
    key, lines = {}, ["# 맞춤 리포트 비교 (모델 이름 가림)", "", "공고마다 좋은 순서대로 적어 주세요. 기준: 정확함, 쓸모, 읽기 쉬움.", ""]
    for nid in ids:
        entries = [(m, json.loads((rep / m / f"{nid}.json").read_text(encoding="utf-8"))) for m in models if (rep / m / f"{nid}.json").exists()]
        entries = [(m, e) for m, e in entries if e["ok"]]  # 실패한 모델은 빼서 이름이 드러나지 않게
        rng.shuffle(entries)
        title = next((s["title"] for s in json.loads(SAMPLE.read_text(encoding="utf-8")) if s["notice_id"].replace(":", "_") == nid), nid)
        lines += [f"## {title}", f"시스템 판정: {entries[0][1]['judgement']}", "", "순위: ", ""]
        key[nid] = {}
        for label, (m, e) in zip("ABCDEFGH", entries):
            key[nid][label] = m
            # 모델마다 다른 제목 표기(#, ##, ###)가 이름을 드러내지 않게 굵은 글씨 한 가지로 맞춘다
            body = "\n".join(
                f"**{ln.lstrip('#').strip().strip('*')}**" if ln.lstrip().startswith("#") else ln
                for ln in (e["output"] or "").strip().splitlines()
            )
            lines += [f"### {label}", "", body, "", "---", ""]
    (OUT / "blind_report.md").write_text("\n".join(lines), encoding="utf-8")
    (OUT / "blind_key.json").write_text(json.dumps(key, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"-> {OUT / 'blind_report.md'} (열쇠는 순위를 매긴 뒤 {OUT / 'blind_key.json'})")


def to_notice(out: dict) -> dict:
    conds = []
    for c in out["conditions"]:
        vals = [int(v) if c["field"] == "grade" and v.isdigit() else v for v in c["values"]]
        if vals:
            conds.append({"field": c["field"], "operator": "in", "value": vals, "evidence": c["evidence"], "validation_status": "validated"})
    return {
        "application_deadline": {"date": out["deadline"]["date"]} if out["deadline"]["date"] else None,
        "eligibility": {
            "conditions": conds,
            "unresolved_conditions": [{"evidence": o["evidence"], "note": o["kind"]} for o in out["other_conditions"]],
            "explicitly_unrestricted": out["everyone"], "extraction_complete": True,
        },
        "title": "",
    }


def evidences(out: dict) -> list[str]:
    ev = [c["evidence"] for c in out["conditions"]] + [o["evidence"] for o in out["other_conditions"]]
    ev += [s["evidence"] for s in out["required_skills"]]
    if out["deadline"]["evidence"]:
        ev.append(out["deadline"]["evidence"])
    return [e for e in ev if e and e.strip()]


def cmd_score(args) -> None:
    sample = {s["notice_id"]: s for s in json.loads(SAMPLE.read_text(encoding="utf-8"))}
    gold = Path(args.gold) if args.gold else GOLD
    gold_rows = read_sheet(gold) if gold.exists() else []
    filled = [r for r in gold_rows if r["누구나"].strip()]
    gold_errors = validate_rows(filled, "gold_20") if filled else []
    table = []
    for name in MODELS:
        run_dir = OUT / "runs" / name
        if not run_dir.exists():
            continue
        base = json.loads((run_dir / "_baseline.json").read_text(encoding="utf-8"))["tokens_in"]
        runs = [json.loads(p.read_text(encoding="utf-8")) for p in run_dir.glob("*.json") if not p.name.startswith("_")]
        okr = [r for r in runs if r["ok"]]
        ev_total = ev_found = 0
        bad = []
        for r in okr:
            src = normalize(sample[r["notice_id"]]["title"] + "\n" + sample[r["notice_id"]]["body_text"])
            for e in evidences(r["output"]):
                ev_total += 1
                if normalize(e) and normalize(e) in src:
                    ev_found += 1
                else:
                    bad.append((r["notice_id"], e[:60]))
        _, _, pin, pout, _ = MODELS[name]
        cost_usd = [] if pin is None else [((max(r["tokens_in"] - base, 0)) * pin + r["tokens_out"] * pout) / 1e6 for r in okr]
        row = {
            "모델": name, "성공": f"{len(okr)}/{len(runs)}",
            "근거_원문_존재율": round(ev_found / ev_total, 3) if ev_total else None, "근거_수": ev_total,
            "건당_원(추정)": round(statistics.mean(cost_usd) * KRW_PER_USD, 2) if cost_usd else None,
            "건당_초(중앙값)": statistics.median([r["seconds"] for r in okr]) if okr else None,
            "건당_토큰(입력·출력 평균)": (round(statistics.mean(max(r["tokens_in"] - base, 0) for r in okr)),
                                    round(statistics.mean(r["tokens_out"] for r in okr))) if okr else None,
            "원문에_없는_근거_예": bad[:3],
        }
        if filled and not gold_errors:
            notices = {r["notice_id"]: to_notice(r["output"]) for r in okr}
            res = evaluate_all([g for g in filled if g["notice_id"] in notices], notices)
            row["채점"] = res
        table.append(row)
    if gold_errors:
        print("정답표 오류(채점 건너뜀):\n" + "\n".join(gold_errors))
    elif not filled:
        print(f"정답표가 비어 있어 마감일·조건·판정 채점은 건너뜀: {gold}")
    for row in table:
        print(f"\n== {row['모델']} 성공 {row['성공']} 근거 원문 존재율 {row['근거_원문_존재율']} ({row['근거_수']}개) "
              f"건당 약 {row['건당_원(추정)']}원 중앙 {row['건당_초(중앙값)']}초 토큰 {row['건당_토큰(입력·출력 평균)']}")
        for nid, e in row["원문에_없는_근거_예"]:
            print(f"  원문에 없음 {nid}: {e}")
        if "채점" in row:
            print(render(row["채점"]))
    if args.json:
        (OUT / "score.json").write_text(json.dumps(table, ensure_ascii=False, indent=1), encoding="utf-8")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("select"); s.add_argument("--force", action="store_true")
    for name in ("run", "report"):
        p = sub.add_parser(name)
        p.add_argument("--model", required=True, choices=list(MODELS))
        p.add_argument("--force", action="store_true")
        p.add_argument("--limit", type=int, default=0)
        p.add_argument("--v2", action="store_true", help="report: 섹션별 JSON 리포트(reports_v2)")
    b = sub.add_parser("blind"); b.add_argument("--seed", type=int, default=1116)
    sc = sub.add_parser("score"); sc.add_argument("--json", action="store_true"); sc.add_argument("--gold")
    args = ap.parse_args(argv)
    {"select": cmd_select, "run": cmd_run, "report": cmd_report, "blind": cmd_blind, "score": cmd_score}[args.cmd](args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
