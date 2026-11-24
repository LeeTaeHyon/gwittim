"""품질 평가 2차: 외부 찾기 변경안 L·X2를 저장본으로 다시 계산한다 (agent-quality-eval-spec §16.5). API를 부르지 않는다.

실행(저장소 루트, worktree의 .venv 파이썬 + PYTHONPATH=.)
  python tools/agent_eval_external2.py --data <메인>/data/local collected-sheet   # X2가 고른 수집분 공고 채점지
  python tools/agent_eval_external2.py --data <메인>/data/local compare           # 기준선 / L / X2 / X2+L

- 재료: 1차 실행 1회차 12개(runs/external/*_r1.json), 가져온 본문 색인(pages/index.json), 1차 채점(grading/external_sheet.grade.json)
- L: 가져오기 상태가 404 등 http 오류, 접속·인증서 오류, 첫 화면으로 넘어감, 빈 본문인 웹 결과를 뺀다. 로그인·robots는 남긴다
- X2: 측정일 고정본(sample/notices.json)의 교외 수집분에서 살아 있고(closed·removed 아님), 마감이 측정일 이후로 적혀 있고,
  분류가 질의와 같고, evaluate 판정이 미충족이 아닌 공고를 먼저 보인다.
  관심 분야 태그가 맞는 것 → 나머지 순, 각각 마감이 가까운 순. 수집분 몫은 요청당 최대 3개, 전체는 5개(지금 화면 개수)
  남는 자리는 웹 결과(1차 순서)로 채운다. 수집분과 같은 웹 결과(D-048 same_notice)는 뺀다
- 수집분 공고의 채점(질의와 맞는지·지원 가능·직접 신청)은 grading/x2_collected.grade.json(Claude 1차).
  수집분은 수집기가 측정일에 확인한 공고라 열림·마감은 자료값으로 둔다
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from backend.agent.external import _norm_url  # noqa: E402
from backend.analysis.external_match import same_notice  # noqa: E402
from backend.recommendation import evaluate  # noqa: E402
from tools.agent_eval_common import data_dir, eval_dir, query_request, quote_in, read_json, write_json  # noqa: E402
from tools.agent_eval_external import open_state  # noqa: E402
from tools.agent_eval_score import _rate, external_runs, read_entries  # noqa: E402

MAX_SHOWN = 5
COLLECTED_MAX = 3
EXTERNAL_SOURCES = ("wevity_contest", "contestkorea_contest")


def collected_for(q: dict, notices: dict, today: str) -> list[tuple[str, str]]:
    """(키, 판정) 목록. X2 규칙 순서, D-048로 묶음, 최대 COLLECTED_MAX."""
    prof, _ = query_request(q)
    cands = []
    for k, n in notices.items():
        if n.get("source_id") not in EXTERNAL_SOURCES or n.get("lifecycle_status") in ("closed", "removed"):
            continue
        day = (n.get("application_deadline") or {}).get("date")
        if not day or day < today or n.get("category") != q["category"]:
            continue
        verdict = evaluate(n["eligibility"], prof)[0]
        if verdict == "not_met":
            continue
        cands.append((q["interest"] not in (n.get("interest_tags") or []), day, k, verdict))
    out = []
    for _, _, k, verdict in sorted(cands):
        if any(same_notice(notices[k], notices[o]) for o, _ in out):
            continue
        out.append((k, verdict))
        if len(out) == COLLECTED_MAX:
            break
    return out


def cmd_collected_sheet(out: Path) -> int:
    notices = read_json(out / "sample/notices.json")
    runs = [r for r in external_runs(out) if r.get("rep") == 1 and "final" in r]
    items = []
    for r in runs:
        for k, verdict in collected_for(r["query"], notices, r["today"]):
            n = notices[k]
            items.append({"id": f"{r['qid']}:{k}", "qid": r["qid"], "query": r["query"], "key": k, "title": n["title"],
                          "category": n["category"], "interest_tags": n.get("interest_tags"), "summary": n.get("summary"),
                          "deadline": (n.get("application_deadline") or {}).get("date"), "verdict": verdict,
                          "conditions": [c.get("evidence") for c in n["eligibility"].get("conditions") or []]
                          + [u.get("evidence") for u in n["eligibility"].get("unresolved_conditions") or []]})
    write_json(out / "grading/x2_collected.json", {"today": runs[0]["today"], "items": items})
    print(f"수집분 채점 항목 {len(items)}개: {dict(Counter(i['qid'] for i in items))}")
    return 0


def variant_items(run: dict, variant: str, notices: dict, index: dict) -> list[dict]:
    web = [{"src": "web", **i} for i in run["final"]]
    if variant in ("L", "X2+L"):
        web = [i for i in web if open_state(index.get(i["url"], {}).get("status")) != "broken"]
    if variant in ("X2", "X2+L"):
        col = [{"src": "collected", "key": k, "title": notices[k]["title"], "url": notices[k].get("source_url"),
                "deadline": (notices[k].get("application_deadline") or {}).get("date"), "verdict": v}
               for k, v in collected_for(run["query"], notices, run["today"])]
        web = [i for i in web if not any(same_notice({"title": i["title"], "application_deadline": {"date": i.get("deadline")}},
                                                     notices[c["key"]]) for c in col)]
        return (col + web)[:MAX_SHOWN]
    return web[:MAX_SHOWN]


def compare(out: Path) -> dict:
    notices = read_json(out / "sample/notices.json")
    index = read_json(out / "pages/index.json")
    sheet = read_json(out / "grading/external_sheet.json")["items"]
    web_grades = read_json(out / "grading/external_sheet.grade.json")["items"]
    by_url = {(s["qid"], s["url"]): web_grades.get(s["id"], {}) for s in sheet if s["outcome"] == "shown"}
    col_path = out / "grading/x2_collected.grade.json"
    col_grades = read_json(col_path)["items"] if col_path.exists() else {}
    app = read_json(out.parent / "notices.json")
    live = [n for n in app.values() if n.get("lifecycle_status") not in ("closed", "removed")]
    runs = [r for r in external_runs(out) if r.get("rep") == 1 and "final" in r]
    result = {}
    for variant in ("baseline", "L", "X2", "X2+L"):
        rows = []
        for r in runs:
            entries = read_entries(r)
            for i in variant_items(r, variant, notices, index):
                if i["src"] == "web":
                    g = by_url.get((r["qid"], i["url"]), {})
                    status = index.get(i["url"], {}).get("status")
                    state = open_state(status)
                    if g.get("unverifiable"):
                        state = "unverifiable"
                    # 인용 대조(E3)
                    quotes = []
                    e = entries.get(_norm_url(i["url"]))
                    page = index.get(i["url"], {})
                    if e and i.get("read") and status == "ok" and page.get("file"):
                        text = (out / "pages" / page["file"]).read_text(encoding="utf-8")
                        for k in ("organizer", "deadline", "target", "grades", "statuses", "school_only", "open_to_all"):
                            q = (e.get(k) or {}).get("quote") if isinstance(e.get(k), dict) else None
                            if isinstance(q, str) and q.strip():
                                quotes.append(quote_in(q, text))
                    dup = any(same_notice({"title": i["title"], "application_deadline": {"date": i.get("deadline")}}, n)
                              for n in live)
                    rows.append({"qid": r["qid"], "src": "web", "state": state, "verdict": i.get("verdict"),
                                 "opens": bool(g.get("opens_and_matches")), "deadline_ok": g.get("deadline_ok"),
                                 "eligible": g.get("eligible"), "direct": g.get("single_notice_direct_apply"),
                                 "off_topic": g.get("failure") == "off_topic", "quotes": quotes, "dup": dup,
                                 "graded": bool(g)})
                else:
                    g = col_grades.get(f"{r['qid']}:{i['key']}", {})
                    rows.append({"qid": r["qid"], "src": "collected", "state": "opened", "verdict": i["verdict"],
                                 "opens": True, "deadline_ok": i["deadline"] >= r["today"], "eligible": g.get("eligible"),
                                 "direct": g.get("single_notice_direct_apply"), "off_topic": g.get("off_topic") is True,
                                 "quotes": [], "dup": True, "graded": bool(g)})
        result[variant] = summarize(rows, runs)
    return result


def usable(x: dict) -> bool:
    return x["opens"] and x["deadline_ok"] is True and x["eligible"] is not False and x["direct"] is True \
        and not x["off_topic"]


def summarize(rows: list[dict], runs: list[dict]) -> dict:
    n_req = len(runs)
    verifiable = [x for x in rows if x["state"] != "unverifiable"]
    known_deadline = [x for x in rows if x["deadline_ok"] is not None]
    quotes = [q for x in rows for q in x["quotes"]]
    met = [x for x in rows if x["verdict"] == "met"]
    per_q = Counter(x["qid"] for x in rows if usable(x))
    shown_q = Counter(x["qid"] for x in rows)
    web = [x for x in rows if x["src"] == "web"]
    return {
        "shown": len(rows), "shown_per_request": round(len(rows) / n_req, 2),
        "collected": sum(x["src"] == "collected" for x in rows),
        "ungraded": sum(not x["graded"] for x in rows),
        "E1_open": _rate(sum(x["opens"] for x in verifiable), len(verifiable)),
        "E1_unverifiable_excluded": len(rows) - len(verifiable),
        "E2_deadline_valid": _rate(sum(x["deadline_ok"] is True for x in known_deadline), len(known_deadline)),
        "E2_deadline_unknown": len(rows) - len(known_deadline),
        "E3_quote_match": _rate(sum(quotes), len(quotes)),
        "E4_met_but_ineligible": sum(x["eligible"] is False for x in met), "E4_met": len(met),
        "E5_usable_per_request": round(sum(per_q.values()) / n_req, 2),
        "E5_charged_zero_usable": sum(1 for r in runs if shown_q[r["qid"]] and not per_q[r["qid"]]),
        "E5_requests_with_3plus": sum(per_q[r["qid"]] >= 3 for r in runs),
        "off_topic": sum(x["off_topic"] for x in rows),
        "E6_duplicate_web": _rate(sum(x["dup"] for x in web), len(web)),
        "E6_collected_share": _rate(sum(x["src"] == "collected" for x in rows), len(rows)),
        "usable_by_query": {r["qid"]: per_q[r["qid"]] for r in runs},
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--data")
    ap.add_argument("cmd", choices=("collected-sheet", "compare"))
    args = ap.parse_args(argv)
    out = eval_dir(data_dir(args.data))
    if args.cmd == "collected-sheet":
        return cmd_collected_sheet(out)
    result = compare(out)
    write_json(out / "scores/external_variants.json", result)
    print(json.dumps({v: {k: x for k, x in s.items() if k != "usable_by_query"} for v, s in result.items()},
                     ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
