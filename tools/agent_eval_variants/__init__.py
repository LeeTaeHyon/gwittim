"""상세 분석 시험 변형 D1·D2 (agent-quality-eval-spec §16.4). 운영 코드(backend/agent)는 고치지 않고 불러 쓰기만 한다.

D1 (본문 입력)
- 입력: 지금 방식 build_messages의 user JSON에 '공고.본문'(원문 본문 전체) 한 칸을 더한다. 서버 판정·4칸 형식은 그대로
- 지침: detail_d1.md = detail_analysis.md 사본 + 본문 칸 설명 1줄 + "본문에 있는 내용을 없다고 말하지 않는다" 1줄
- 후처리: scrub_codes → split_long_lines → ground_report. ground_report의 역량 근거는 '본문 대조'로 바꾼 쪽을 골랐다
  (이유: '원문에서 확인할 조건'이 있는 공고가 표본의 일부뿐이라, 그대로 두면 본문에서 온 역량 줄이 전부 지워져
  D1이 역량 칸에 준 효과를 잴 수 없다). 방법: ground_report에 넘기는 공고 사본의 unresolved_conditions 뒤에
  본문 줄을 근거로 덧붙인다. 원래 조건이 앞이라 '(우대)' 구분은 그대로 살아 있다. 운영 함수는 바꾸지 않음
D2 (D1 + 인용 대조)
- 지침: detail_d2.md = D1 + 칸 값을 줄 목록 {text, basis, quote}로 받는 형식
- 후처리: basis '본문' 줄은 quote가 본문에 문자열로 있을 때만(quote_in) 남긴다. '판정'·'학생'·'고정' 줄은 인용 없이 남긴다.
  남은 text를 줄바꿈으로 이어 4칸 문자열로 만든 뒤 D1과 같은 후처리. 인용은 리포트에 넣지 않는다
"""
from __future__ import annotations

import json
from datetime import date
from pathlib import Path

from backend.agent.payload import build_payload
from backend.agent.prompt import build_messages, ground_report, load_harness, scrub_codes, split_long_lines
from backend.recommendation import evaluate
from tools.agent_eval_common import quote_in

HERE = Path(__file__).resolve().parent
SYSTEM = {v: load_harness(HERE / f"detail_{v.lower()}.md") for v in ("D1", "D2", "D3", "D4")}
FIELDS = ("fit", "eligibility", "todo", "skills")
BASES = ("본문", "판정", "학생", "고정")


def body_text(record: dict) -> str:
    return (((record or {}).get("raw") or {}).get("body_text") or "").strip()


def build(variant: str, notice: dict, record: dict, prof: dict, chips: dict, today: date) -> tuple[str, str, str]:
    verdict = evaluate(notice["eligibility"], prof)
    _, user = build_messages(notice, build_payload(prof, chips), verdict, today)
    material = json.loads(user)
    material["공고"]["본문"] = body_text(record)
    return SYSTEM[variant], json.dumps(material, ensure_ascii=False, indent=1), verdict[0]


def notice_with_body(notice: dict, record: dict) -> dict:
    """역량 근거 대조용 공고 사본: 원래 조건 뒤에 본문 줄을 근거로 덧붙인다."""
    el = dict(notice.get("eligibility") or {})
    lines = [ln.strip() for ln in body_text(record).split("\n") if len(ln.strip()) >= 2]
    el["unresolved_conditions"] = list(el.get("unresolved_conditions") or []) + [
        {"evidence": ln, "note": None} for ln in lines]
    return {**notice, "eligibility": el}


def verify_quotes(raw: dict, body: str) -> tuple[dict, dict]:
    """D2: 줄 목록 -> 4칸 문자열. (리포트, 집계 {'lines', 'dropped', 'dropped_by_field', 'basis', 'emptied_fields'})."""
    report, stats = {}, {"lines": 0, "dropped": 0, "dropped_by_field": {}, "basis": {}, "emptied_fields": [],
                         "malformed": 0}
    for f in FIELDS:
        value = raw.get(f)
        items = value if isinstance(value, list) else [{"text": value, "basis": "본문", "quote": None}]
        kept = []
        for it in items:
            if not isinstance(it, dict) or not isinstance(it.get("text"), str) or not it["text"].strip():
                stats["malformed"] += 1
                continue
            stats["lines"] += 1
            basis = it.get("basis") if it.get("basis") in BASES else "본문"
            stats["basis"][basis] = stats["basis"].get(basis, 0) + 1
            if basis == "본문" and not quote_in(str(it.get("quote") or ""), body):
                stats["dropped"] += 1
                stats["dropped_by_field"][f] = stats["dropped_by_field"].get(f, 0) + 1
                continue
            kept.append(it["text"].strip())
        if not kept:
            stats["emptied_fields"].append(f)
        report[f] = "\n".join(kept)
    return report, stats


def postprocess(variant: str, raw: dict, notice: dict, record: dict, verdict: str, today: date) -> tuple[dict, dict]:
    """(최종 리포트, 후처리 기록)."""
    post = {}
    if variant == "D2":
        raw, post["quote_check"] = verify_quotes(raw, body_text(record))
    report, scrubbed = scrub_codes(raw)
    report, split = split_long_lines(report)
    report, grounded = ground_report(report, notice_with_body(notice, record), verdict, today)
    post.update({"scrubbed": scrubbed, "split": split, "grounded": grounded})
    return report, post

# 3차 (§17.2)
# - D3: D1 + 줄 수 상한(fit 최대 4줄, todo 1~4줄)과 "쓸 내용이 없으면 줄을 줄입니다" 한 문장. 입력·후처리는 D1과 같다
# - D4: D3 + 역량 근거를 '원문에서 확인할 조건 또는 공고 본문'으로. 후처리의 역량 대조는 D1부터 본문 대조라 그대로
