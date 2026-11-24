"""품질 평가 4단계: 채점 (agent-quality-eval-spec §5.5·§6.4·§7).

실행(저장소 루트, worktree의 .venv 파이썬 + PYTHONPATH=.)
  python tools/agent_eval_score.py --data <메인>/data/local detail-sheets    # 방식 이름을 가린 채점지(공고마다 1개)
  python tools/agent_eval_score.py --data <메인>/data/local detail           # 채점 결과 -> M1~M6, 실패 유형
  python tools/agent_eval_score.py --data <메인>/data/local external-sheets  # 외부 찾기 결과 페이지 채점지
  python tools/agent_eval_score.py --data <메인>/data/local external         # E1~E9

상세 분석 채점지 (grading/detail/NN.json)
- 공고 본문, 무료 화면 줄, 정답 초안 사실(F1…), 리포트 6개(A·G × P1~P3)를 R1~R6으로 섞어 방식 이름을 지운다.
  섞는 순서는 공고마다 씨앗으로 고정하고, 열쇠는 grading/detail_key.json에 따로 둔다(채점자는 열지 않음)
- 주장 단위는 리포트 칸의 줄 하나다. 고정 문장(역량 확인 어려움·할 일 없음)은 주장에서 빼고 M5로만 센다
- 채점자는 NN.grade.json에 주장마다 {label, gold, forced}를 쓴다
  - label: grounded(원문·서버 판정·프로필로 뒷받침) / unsupported(근거를 찾을 수 없음) / contradicts(원문이나 서버 판정과 어긋남)
    / profile_only(프로필 값을 옮기기만 함 → M2 분모에서 뺌)
  - gold: 그 줄이 담은 정답 사실 id 목록, forced: 칩·관심 분야를 공고와 근거 없이 억지로 이은 줄이면 true
- 한계: 형식(꼬리표 '맞음:' 등)으로 A와 G를 가를 수 있어 가림은 완전하지 않다
"""
from __future__ import annotations

import argparse
import csv
import json
import random
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from backend.agent.prompt import _student  # noqa: E402
from backend.agent.payload import build_payload  # noqa: E402
from tools.agent_eval_common import (  # noqa: E402
    PROFILE_NAMES, data_dir, eval_dir, free_screen_text, profile, quote_in, read_json, school_of, write_json,
)
from tools.agent_eval_sample import body_of  # noqa: E402
from tools.evalstats import wilson  # noqa: E402

FIXED = re.compile(r"요구 역량을 확인하기 어렵습니다|이번 모집은 지원 전에 할 일이 없습니다")
FIELDS = ("fit", "eligibility", "todo", "skills")
LABELS = ("grounded", "unsupported", "contradicts", "profile_only")
VERDICT_KO = {"met": "충족", "not_met": "미충족", "needs_check": "확인 필요"}


def claims(report: dict) -> list[tuple[str, str]]:
    """(칸, 줄) 목록. 고정 문장은 뺀다."""
    out = []
    for f in FIELDS:
        for ln in str(report.get(f, "")).split("\n"):
            ln = ln.strip()
            if ln and not FIXED.search(ln):
                out.append((f, ln))
    return out


def fixed_flags(report: dict) -> dict:
    return {"skills_fixed": bool(FIXED.search(str(report.get("skills", "")))),
            "todo_fixed": "이번 모집은 지원 전에 할 일이 없습니다" in str(report.get("todo", ""))}


def read_gold(path: Path) -> dict[str, list[dict]]:
    with path.open(encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    gold = defaultdict(list)
    for r in rows:
        gold.setdefault(r["notice_id"], [])
        if (r.get("fact") or "").strip() not in ("", "없음"):
            gold[r["notice_id"]].append(r)
    for facts in gold.values():
        for i, r in enumerate(facts, 1):
            r["id"] = f"F{i}"
    return dict(gold)


def read_human_gold(path: Path) -> dict[str, list[dict]]:
    """gold/dev_gold_human.csv(agent_eval_gold.py가 만든 합집합, id H1…)."""
    with path.open(encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    out = defaultdict(list)
    for r in rows:
        out.setdefault(r["notice_id"], [])
        if (r.get("fact") or "").strip() not in ("", "없음"):
            out[r["notice_id"]].append(r)
    return dict(out)


def _facts(rows: list[dict]) -> list[dict]:
    return [{"id": g["id"], "fact": g["fact"], "quote": g["quote"], "kind": g["kind"],
             "on_free_screen": g["on_free_screen"]} for g in rows]


def load_runs(out: Path) -> dict[tuple[str, str, str], dict]:
    runs = {}
    for p in (out / "runs/detail").glob("*/*.json"):
        r = read_json(p)
        runs[(r["key"], r["profile"], r["variant"])] = r
    return runs


REGRADE_SEED = 20261126
REGRADE_N = 10


def cmd_detail_sheets(out: Path, variants=("A", "G"), sheets_name: str = "detail", regrade: tuple = ()) -> int:
    """채점지. regrade: (방식들) - 공고 REGRADE_N건에 한해 1차 방식 리포트를 섞어 다시 채점(채점자 흔들림 확인)."""
    manifest = read_json(out / "sample/manifest.json")
    dev = [r for r in manifest["sample"] if r["split"] == "dev"]
    notices, records = read_json(out / "sample/notices.json"), read_json(out / "sample/records.json")
    gold = read_gold(out / "gold/dev_draft.csv")
    human_path = out / "gold/dev_gold_human.csv"
    human = read_human_gold(human_path) if sheets_name != "detail" and human_path.exists() else None
    runs = load_runs(out)
    sheets = out / "grading" / sheets_name
    sheets.mkdir(parents=True, exist_ok=True)
    key, missing = {}, []
    regrade_keys = set(random.Random(REGRADE_SEED).sample(sorted(r["key"] for r in dev), REGRADE_N)) if regrade else set()
    for n, row in enumerate(dev, 1):
        k = row["key"]
        notice = notices[k]
        reports = []
        for pname in PROFILE_NAMES:
            for v in tuple(variants) + (tuple(regrade) if k in regrade_keys else ()):
                run = runs.get((k, pname, v))
                if run is None or "error" in run:
                    missing.append(f"{k} {pname} {v}")
                    continue
                reports.append((pname, v, run))
        rng = random.Random(f"{k}-blind" if sheets_name == "detail" else f"{k}-blind-{sheets_name}")
        rng.shuffle(reports)
        sheet_reports = []
        for i, (pname, v, run) in enumerate(reports, 1):
            label = f"R{i}"
            key[f"{n:02}:{label}"] = {"key": k, "profile": pname, "variant": v, "regrade": v in regrade}
            prof, chips = profile(pname, school_of(row["group"]))
            sheet_reports.append({
                "label": label, "profile": pname, "student": _student(build_payload(prof, chips)),
                "server_verdict": VERDICT_KO.get(run["verdict"], run["verdict"]),
                "claims": [{"id": f"{label}.{f}.{j}", "field": f, "text": t}
                           for j, (f, t) in enumerate(claims(run["report"]), 1)],
                "fixed_lines_removed": fixed_flags(run["report"]),
            })
        write_json(sheets / f"{n:02}.json", {
            "sheet": f"{n:02}", "notice_key": k, "today": runs.get((k, "P1", "A"), {}).get("today"),
            "title": notice["title"], "body": body_of(records[k]).strip(), "free_screen": free_screen_text(notice),
            "gold_facts": _facts(gold.get(k, [])),
            **({"human_facts": _facts(human.get(k, []))} if human is not None else {}),
            "reports": sheet_reports,
        })
    write_json(out / "grading" / f"{sheets_name}_key.json", key)
    print(f"채점지 {len(dev)}개, 리포트 {len(key)}개" + (f", 빠진 실행 {len(missing)}개: {missing[:5]}" if missing else ""))
    return 1 if missing else 0


def _rate(k: int, n: int) -> dict:
    lo, hi = wilson(k, n) if n else (None, None)
    return {"k": k, "n": n, "rate": round(k / n, 3) if n else None,
            "ci95": [round(lo, 3), round(hi, 3)] if n else None}


# "공고에 없다"고 말하는 줄(어긋남으로 채점됐으면 본문에 있는 것을 없다고 한 줄)
ABSENT = re.compile(r"나와 있지 않|나오지 않|제시되지 않|적혀 있지 않|명시되지 않|알 수 없|없어|확인할 수 없|확인되지 않|"
                    r"구체적으로 나오지|공고 자료에|공고에서 확인|붙임|첨부")
VERDICT_LINE = re.compile(r"^(충족|미충족|확인 필요)\s*:")


def absent_wrong(claim: dict, grade: dict) -> bool:
    return grade.get("label") == "contradicts" and not (claim["field"] == "eligibility" and VERDICT_LINE.match(claim["text"]))         and bool(ABSENT.search(claim["text"]))


def score_detail(out: Path, sheets_name: str = "detail", skip_regrade: bool = True, basis: str = "draft") -> dict:
    """basis: draft(Claude 초안, 칸 gold) / human(사람 합집합, 칸 hgold). 1차 채점지의 hgold는 detail_h 채점에서 읽는다."""
    key = read_json(out / "grading" / f"{sheets_name}_key.json")
    dates = {r["key"]: r for r in read_json(out / "sample/eval_dates.json")["rows"]}
    gold = read_gold(out / "gold/dev_draft.csv")
    runs = load_runs(out)
    per = defaultdict(lambda: defaultdict(list))  # 묶음(all/visible) -> 방식 -> 리포트별 기록
    ungraded = []
    for sheet_path in sorted((out / "grading" / sheets_name).glob("[0-9][0-9].json")):
        sheet = read_json(sheet_path)
        grade_path = sheet_path.with_suffix(".grade.json")
        if not grade_path.exists():
            ungraded.append(sheet["sheet"])
            continue
        grades = read_json(grade_path)["claims"]
        if basis == "human":
            h_path = out / "grading/detail_h" / grade_path.name if sheets_name == "detail" else None
            if h_path is not None:
                if not h_path.exists():
                    ungraded.append(f"h{sheet['sheet']}")
                    continue
                hg = read_json(h_path)["claims"]
                grades = {cid: {**g, "hgold": hg.get(cid, {}).get("hgold", [])} for cid, g in grades.items()}
            human_sheet = read_json(out / "grading/detail_h" / sheet_path.name) if sheets_name == "detail" else sheet
            facts = {g["id"]: g for g in human_sheet["human_facts"]}
            grades = {cid: {**g, "gold": g.get("hgold") or []} for cid, g in grades.items()}
        else:
            facts = {g["id"]: g for g in sheet["gold_facts"]}
        for rep in sheet["reports"]:
            info = key[f"{sheet['sheet']}:{rep['label']}"]
            if skip_regrade and info.get("regrade"):
                continue
            run = runs[(info["key"], info["profile"], info["variant"])]
            labels = [grades.get(c["id"], {}) for c in rep["claims"]]
            covered = set()
            for g in labels:
                covered |= {x for x in g.get("gold") or [] if x in facts}
            new_facts = {f for f in covered if facts[f]["on_free_screen"] == "아니요"}
            gold_new_total = sum(f["on_free_screen"] == "아니요" for f in facts.values())
            rec = {
                "sheet": sheet["sheet"], "key": info["key"], "profile": info["profile"],
                "claims": len(rep["claims"]),
                "labels": Counter(g.get("label", "ungraded") for g in labels),
                "forced": sum(bool(g.get("forced")) for g in labels),
                "gold_total": len(facts), "gold_covered": len(covered), "new_facts": len(new_facts),
                "gold_new_total": gold_new_total,
                "missed_new": [facts[f] for f in facts if f not in covered and facts[f]["on_free_screen"] == "아니요"],
                "fixed": fixed_flags(run["report"]),
                "quality": run.get("quality", []), "format": run.get("format", []),
                "user": run.get("user", ""),
                "bad_claims": [{"text": c["text"], "label": g.get("label")} for c, g in zip(rep["claims"], labels)
                               if g.get("label") in ("unsupported", "contradicts")],
                "forced_claims": [c["text"] for c, g in zip(rep["claims"], labels) if g.get("forced")],
                "tokens": run.get("tokens"), "seconds": run.get("seconds"),
                "absent_wrong": sum(absent_wrong(c, g) for c, g in zip(rep["claims"], labels)),
                "quote_check": (run.get("post") or {}).get("quote_check"),
                "lines_by_field": {f: len([ln for ln in str(run["report"].get(f, "")).split("\n") if ln.strip()])
                                   for f in FIELDS},
                "chars": sum(len(str(run["report"].get(f, ""))) for f in FIELDS),
            }
            per["all"][info["variant"]].append(rec)
            if dates[info["key"]]["visible"]:
                per["visible"][info["variant"]].append(rec)

    def summarize(recs: list[dict]) -> dict:
        lab = Counter()
        for r in recs:
            lab.update(r["labels"])
        judged = lab["grounded"] + lab["unsupported"] + lab["contradicts"]
        with_gold = [r for r in recs if r["gold_total"]]
        rich = [r for r in recs if r["gold_new_total"] >= 2]
        return {
            "reports": len(recs),
            "M1_contradicts": lab["contradicts"],
            "M1_reports_with_contradiction": sum(r["labels"]["contradicts"] > 0 for r in recs),
            "M1_contradict_rate": _rate(lab["contradicts"], sum(r["claims"] for r in recs)),
            "M1_absent_wrong": sum(r["absent_wrong"] for r in recs),
            "M2_grounded": _rate(lab["grounded"], judged),
            "M3_recall": _rate(sum(r["gold_covered"] for r in with_gold), sum(r["gold_total"] for r in with_gold)),
            "M4_new_facts_per_report": round(sum(r["new_facts"] for r in recs) / len(recs), 2) if recs else None,
            "M4_new_facts_per_report_rich": round(sum(r["new_facts"] for r in rich) / len(rich), 2) if rich else None,
            "M4_zero_new_reports": _rate(sum(r["new_facts"] == 0 for r in recs), len(recs)),
            "M5_skills_fixed": _rate(sum(r["fixed"]["skills_fixed"] for r in recs), len(recs)),
            "M5_todo_fixed": _rate(sum(r["fixed"]["todo_fixed"] for r in recs), len(recs)),
            "M6_quality_errors": sum(len(r["quality"]) for r in recs),
            "M6_reports_with_quality_error": sum(bool(r["quality"]) for r in recs),
            "M6_format_findings": sum(len(r["format"]) for r in recs),
            "unsupported_claims": lab["unsupported"], "profile_only_claims": lab["profile_only"],
            "forced_claims": sum(r["forced"] for r in recs), "claims": sum(r["claims"] for r in recs),
            "ungraded_claims": lab["ungraded"],
            "avg_seconds": round(sum(r["seconds"] or 0 for r in recs) / len(recs), 1) if recs else None,
            "avg_tokens_in": round(sum((r["tokens"] or [0, 0])[0] or 0 for r in recs) / len(recs)) if recs else None,
            "avg_tokens_out": round(sum((r["tokens"] or [0, 0])[1] or 0 for r in recs) / len(recs)) if recs else None,
            "D2_lines": sum((r["quote_check"] or {}).get("lines", 0) for r in recs),
            "D2_dropped_lines": sum((r["quote_check"] or {}).get("dropped", 0) for r in recs),
            "D2_reports_with_emptied_field": sum(bool((r["quote_check"] or {}).get("emptied_fields")) for r in recs),
            "D2_emptied_fields": dict(Counter(f for r in recs for f in (r["quote_check"] or {}).get("emptied_fields", []))),
            "lines_per_report": round(sum(sum(r["lines_by_field"].values()) for r in recs) / len(recs), 2) if recs else None,
            "claims_per_report": round(sum(r["claims"] for r in recs) / len(recs), 2) if recs else None,
            "facts_per_claim": round(sum(r["gold_covered"] for r in recs) / max(1, sum(r["claims"] for r in recs)), 3),
            "lines_by_field": {f: {"mean": round(sum(r["lines_by_field"][f] for r in recs) / len(recs), 2),
                                   "dist": dict(sorted(Counter(r["lines_by_field"][f] for r in recs).items()))}
                               for f in FIELDS} if recs else {},
            "chars_median": sorted(r["chars"] for r in recs)[len(recs) // 2] if recs else None,
            "chars_max": max(r["chars"] for r in recs) if recs else None,
        }

    return {"ungraded_sheets": ungraded,
            "summary": {grp: {v: summarize(recs) for v, recs in by.items()} for grp, by in per.items()},
            "records": {v: recs for v, recs in per["all"].items()}}


def failure_types(result: dict, out: Path) -> dict:
    """A(지금 방식)의 실패 유형 건수와 예. 원인 축: 빠진 새 사실이 A 입력에 없으면 '입력 부족'."""
    recs = result["records"].get("A", [])
    types = defaultdict(lambda: {"count": 0, "examples": [], "cause": Counter()})

    def add(name: str, example: str, cause: str):
        t = types[name]
        t["count"] += 1
        t["cause"][cause] += 1
        if len(t["examples"]) < 2:
            t["examples"].append(example)

    for r in recs:
        tag = f"{r['key']} {r['profile']}"
        if r["new_facts"] == 0 and r["gold_new_total"] > 0:
            add("무료 화면 되풀이(새 사실 0개)", f"{tag}: 정답 새 사실 {r['gold_new_total']}개 중 0개", "입력 부족")
        for c in r["bad_claims"]:
            add("원문과 어긋남" if c["label"] == "contradicts" else "근거 없음", f"{tag}: {c['text']}", "모델")
        for m in r["missed_new"]:
            cause = "지침" if quote_in(m["quote"], r["user"]) else "입력 부족"
            add("원문에 있는데 빠짐(새 사실)", f"{tag}: {m['fact']}", cause)
        if r["fixed"]["skills_fixed"]:
            add("고정 문장(역량)", tag, "후처리" if "원문에서 확인할 조건\": []" in r["user"] else "후처리·지침")
        if r["fixed"]["todo_fixed"]:
            add("고정 문장(할 일)", tag, "후처리")
        for t in r["forced_claims"]:
            add("칩과 억지 연결", f"{tag}: {t}", "지침")
    return {k: {**v, "cause": dict(v["cause"])} for k, v in sorted(types.items(), key=lambda kv: -kv[1]["count"])}


def cmd_detail(out: Path) -> int:
    result = score_detail(out)
    ft = failure_types(result, out)
    write_json(out / "scores/detail.json", {"summary": result["summary"], "failure_types": ft,
                                            "ungraded_sheets": result["ungraded_sheets"]})
    print(json.dumps(result["summary"], ensure_ascii=False, indent=1))
    print(json.dumps({k: {"count": v["count"], "cause": v["cause"]} for k, v in ft.items()}, ensure_ascii=False, indent=1))
    if result["ungraded_sheets"]:
        print(f"채점 안 된 채점지: {result['ungraded_sheets']}")
    return 0


# ---------- 외부 찾기 ----------

def external_runs(out: Path) -> list[dict]:
    return [read_json(p) for p in sorted((out / "runs/external").glob("*.json"))]


def read_entries(run: dict) -> dict[str, dict]:
    """원문 읽기 단계가 낸 항목(주소별)."""
    from backend.agent.external import _norm_url
    from backend.agent.llm import ReportFormatError, extract_json

    try:
        data = extract_json((run.get("read") or {}).get("text") or "")
    except ReportFormatError:
        return {}
    return {_norm_url(e["url"]): e for e in data.get("items") or [] if isinstance(e, dict) and isinstance(e.get("url"), str)}


def cmd_external_sheets(out: Path) -> int:
    """결과(최종 목록 + 미충족으로 빠진 것)마다 가져온 본문 앞부분과 함께 채점지를 만든다."""
    from backend.agent.external import _norm_url, eligibility_from_page
    from backend.recommendation import evaluate

    index = read_json(out / "pages/index.json")
    sheet = []
    for run in external_runs(out):
        if run.get("rep") != 1 or "final" not in run:
            continue
        prof, _ = profile("P1", "mjc")
        prof["interest_ids"] = [run["query"]["interest"]]
        entries = read_entries(run)
        final_urls = {_norm_url(i["url"]) for i in run["final"]}
        items = [dict(i, outcome="shown") for i in run["final"]]
        for i in run["grounded"]["items"]:  # 미충족으로 빠진 것
            e = entries.get(_norm_url(i["url"]))
            if _norm_url(i["url"]) not in final_urls and e is not None:
                v, _ = evaluate(eligibility_from_page(e), prof)
                items.append(dict(i, outcome=f"excluded_{v}"))
        for i in items:
            page = index.get(i["url"], {})
            text = ""
            if page.get("file"):
                text = (out / "pages" / page["file"]).read_text(encoding="utf-8")
            sheet.append({"id": f"{run['qid']}-{len(sheet) + 1:03}", "qid": run["qid"], "query": run["query"],
                          "title": i["title"], "url": i["url"], "outcome": i["outcome"],
                          "verified": i.get("verified"), "shown_deadline": i.get("deadline"),
                          "verdict": i.get("verdict"), "target_quote": i.get("target"),
                          "page_status": page.get("status"), "page_text": text[:6000]})
    write_json(out / "grading/external_sheet.json", {"today": external_runs(out)[0]["today"], "items": sheet})
    print(f"외부 찾기 채점 항목 {len(sheet)}개")
    return 0


def cmd_external(out: Path) -> int:
    from backend.agent.external import _norm_url
    from backend.analysis.external_match import same_notice

    runs = external_runs(out)
    index = read_json(out / "pages/index.json") if (out / "pages/index.json").exists() else {}
    grades_path = out / "grading/external_sheet.grade.json"
    grades = read_json(grades_path)["items"] if grades_path.exists() else {}
    sheet = {s["id"]: s for s in read_json(out / "grading/external_sheet.json")["items"]} \
        if (out / "grading/external_sheet.json").exists() else {}
    app = read_json(out.parent / "notices.json")
    live = [n for n in app.values() if n.get("lifecycle_status") not in ("closed", "removed")]
    base = [r for r in runs if r.get("rep") == 1 and "final" in r]

    shown = [(r, i) for r in base for i in r["final"]]
    pages = [index.get(i["url"], {}) for _, i in shown]
    fetched_ok = sum(p.get("status") == "ok" for p in pages)
    # E3 인용 일치: 화면에 보인 결과 중 원문을 읽은 것의 인용문이 가져온 본문에 있는지
    q_total = q_match = q_unchecked = 0
    for r, i in shown:
        e = read_entries(r).get(_norm_url(i["url"]))
        if not e or not i.get("read"):
            continue
        page = index.get(i["url"], {})
        text = (out / "pages" / page["file"]).read_text(encoding="utf-8") if page.get("file") else None
        for k in ("organizer", "deadline", "target", "grades", "statuses", "school_only", "open_to_all"):
            q = (e.get(k) or {}).get("quote") if isinstance(e.get(k), dict) else None
            if isinstance(q, str) and q.strip():
                if text is None or page.get("status") != "ok":
                    q_unchecked += 1
                    continue
                q_total += 1
                q_match += quote_in(q, text)
    # E6 중복: 앱에 살아 있는 공고와 같은 결과
    dup = sum(any(same_notice({"title": i["title"], "application_deadline": {"date": i.get("deadline")}}, n)
                  for n in live) for _, i in shown)
    # E7 안정성: 같은 질의 회차별 결과 주소 겹침(자카드)
    by_q = defaultdict(list)
    for r in runs:
        if "final" in r:
            by_q[r["qid"]].append({_norm_url(i["url"]) for i in r["final"]})
    stab = {}
    for q, sets in by_q.items():
        if len(sets) >= 2:
            pairs = [(a, b) for x, a in enumerate(sets) for b in sets[x + 1:]]
            stab[q] = round(sum(len(a & b) / len(a | b) if a | b else 1.0 for a, b in pairs) / len(pairs), 2)
    # 사람·Claude 판단 칸(E1 핵심 낱말, E2 마감, E4 자격, E5 직접 신청)
    g_shown = [(sheet[i], g) for i, g in grades.items() if i in sheet and sheet[i]["outcome"] == "shown"]
    g_excl = [(sheet[i], g) for i, g in grades.items() if i in sheet and sheet[i]["outcome"].startswith("excluded")]
    e1 = sum(bool(g.get("opens_and_matches")) for _, g in g_shown)
    today = read_json(out / "grading/external_sheet.json")["today"] if sheet else ""
    e2_known = [(s, g) for s, g in g_shown if g.get("deadline_on_page")]
    e2 = sum(g["deadline_on_page"] >= today for _, g in e2_known)
    met = [(s, g) for s, g in g_shown if s["verdict"] == "met"]
    e4_wrong = sum(g.get("eligible") is False for _, g in met)
    e4_missed = sum(g.get("eligible") is True for _, g in g_excl)
    usable = defaultdict(int)
    for s, g in g_shown:
        if g.get("opens_and_matches") and g.get("deadline_ok") and g.get("eligible") is not False \
                and g.get("single_notice_direct_apply"):
            usable[s["qid"]] += 1
    charged = [r for r in base if r["charged"]]
    # E8 재현율: 공모전 질의마다, 측정일 교외 수집분 중 살아 있고 마감이 남은 공모전 + 관심 분야 태그가 맞는 것(D-048로 중복 묶음)
    today_s = base[0]["today"] if base else ""
    pool_all = [(k, n) for k, n in app.items() if n.get("source_id") in ("wevity_contest", "contestkorea_contest")
                and n.get("lifecycle_status") not in ("closed", "removed") and n.get("category") == "contest"
                and ((n.get("application_deadline") or {}).get("date") or "9999") >= today_s]
    recall, pools = {}, {}
    for r in base:
        if r["query"]["category"] != "contest":
            continue
        pool = []
        for k, n in pool_all:
            if r["query"]["interest"] in (n.get("interest_tags") or []) and not any(same_notice(n, app[p]) for p in pool):
                pool.append(k)
        found = [k for k in pool if any(same_notice({"title": i["title"], "application_deadline":
                                                     {"date": i.get("deadline")}}, app[k])
                                        or _norm_url(i["url"]) == _norm_url(app[k].get("source_url") or "")
                                        for i in r["final"])]
        pools[r["qid"]] = [{"key": k, "title": app[k]["title"]} for k in pool]
        recall[r["qid"]] = {"found": len(found), "pool": len(pool), "found_keys": found}
    write_json(out / "grading/recall_pool.json", {"basis": "interest_tags 기계 후보(사람 확인 전)", "pools": pools})
    summary = {
        "runs": len(runs), "baseline_runs": len(base),
        "cost_krw_total": round(sum(r.get("cost_total") or 0 for r in runs), 2),
        "cost_krw_per_request": round(sum(r.get("cost_total") or 0 for r in base) / len(base), 2) if base else None,
        "seconds_per_request": round(sum(r.get("seconds_total") or 0 for r in base) / len(base), 1) if base else None,
        "shown_items": len(shown), "shown_per_request": round(len(shown) / len(base), 2) if base else None,
        "charged_requests": len(charged),
        "fetch_status": dict(Counter(p.get("status", "not_fetched") for p in pages)),
        "E1_open_and_match": _rate(e1, len(g_shown)) if g_shown else _rate(fetched_ok, len(shown)),
        "E1_basis": "채점(핵심 낱말)" if g_shown else "가져오기 ok만(핵심 낱말 미확인)",
        "E2_deadline_valid": _rate(e2, len(e2_known)),
        "E2_shown_deadline_matches_page": _rate(sum(s["shown_deadline"] == g.get("deadline_on_page")
                                                    for s, g in e2_known if s["shown_deadline"]),
                                                sum(bool(s["shown_deadline"]) for s, _ in e2_known)),
        "E3_quote_match": _rate(q_match, q_total), "E3_unchecked_quotes": q_unchecked,
        "E4_met_but_ineligible": e4_wrong, "E4_met_checked": len(met),
        "E4_excluded_but_eligible": e4_missed, "E4_excluded_checked": len(g_excl),
        "E5_usable_per_request": round(sum(usable.values()) / len(base), 2) if base and grades else None,
        "E5_charged_zero_usable": sum(1 for r in charged if usable.get(r["qid"], 0) == 0) if grades else None,
        "E6_duplicate_of_app": _rate(dup, len(shown)),
        "E7_stability_jaccard": stab,
        "E8_recall_contest": recall,
        "verified_share": _rate(sum(bool(i.get("verified")) for _, i in shown), len(shown)),
        "read_share": _rate(sum(bool(i.get("read")) for _, i in shown), len(shown)),
    }
    write_json(out / "scores/external.json", summary)
    print(json.dumps(summary, ensure_ascii=False, indent=1))
    return 0


# ---------- 2차 (§16.4) ----------

def _claim_labels(out: Path, sheets_name: str, only_regrade: bool) -> dict:
    """(공고, 프로필, 방식, 주장 순번) -> label."""
    key = read_json(out / "grading" / f"{sheets_name}_key.json")
    labels = {}
    for sheet_path in sorted((out / "grading" / sheets_name).glob("[0-9][0-9].json")):
        grade_path = sheet_path.with_suffix(".grade.json")
        if not grade_path.exists():
            continue
        sheet, grades = read_json(sheet_path), read_json(grade_path)["claims"]
        for rep in sheet["reports"]:
            info = key[f"{sheet['sheet']}:{rep['label']}"]
            if only_regrade and not info.get("regrade"):
                continue
            for i, c in enumerate(rep["claims"]):
                labels[(info["key"], info["profile"], info["variant"], i)] = grades.get(c["id"], {}).get("label")
    return labels


def grader_agreement(out: Path, first_name: str = "detail", second_name: str = "detail2") -> dict:
    """앞 회차 리포트를 뒤 회차 채점지에 섞어 다시 채점한 결과와 앞 회차 채점의 주장 단위 일치율."""
    from tools.evalstats import cohen_kappa

    first = _claim_labels(out, first_name, only_regrade=False)
    second = _claim_labels(out, second_name, only_regrade=True)
    both = [k for k in second if k in first and first[k] and second[k]]
    a, b = [first[k] for k in both], [second[k] for k in both]
    same = sum(x == y for x, y in zip(a, b))
    bad = lambda x: x in ("unsupported", "contradicts")  # noqa: E731
    return {"claims": len(both), "agreement": _rate(same, len(both)),
            "kappa": round(cohen_kappa(a, b), 3) if both else None,
            "bad_vs_good_agreement": _rate(sum(bad(x) == bad(y) for x, y in zip(a, b)), len(both)),
            "pairs": dict(Counter(f"{x}->{y}" for x, y in zip(a, b) if x != y))}


def cost_estimate(tokens_in: float, tokens_out: float, overhead_in: int) -> dict:
    """운영 단가(DeepSeek, 할인·피크) 기준 건당 원가 추정. opencode 토큰에서 덧붙임 지시문 몫(overhead_in)을 뺀다."""
    from backend.agent.llm import DEEPSEEK_PRICE_OFF_PEAK, DEEPSEEK_PRICE_PEAK, estimate_cost_krw

    tin = max(0, round(tokens_in - overhead_in))
    return {"input_tokens_est": tin, "output_tokens": round(tokens_out),
            "krw_off_peak": estimate_cost_krw(tin, round(tokens_out), *DEEPSEEK_PRICE_OFF_PEAK),
            "krw_peak": estimate_cost_krw(tin, round(tokens_out), *DEEPSEEK_PRICE_PEAK)}


def cmd_detail_h_sheets(out: Path) -> int:
    """1차 채점지 사본에 사람 정답 사실만 바꿔 넣는다. 주장 id·문장은 1차와 같다. 채점자는 hgold만 쓴다."""
    human = read_human_gold(out / "gold/dev_gold_human.csv")
    dst = out / "grading/detail_h"
    dst.mkdir(parents=True, exist_ok=True)
    n = 0
    for path in sorted((out / "grading/detail").glob("[0-9][0-9].json")):
        sheet = read_json(path)
        sheet.pop("gold_facts", None)
        sheet["human_facts"] = _facts(human.get(sheet["notice_key"], []))
        write_json(dst / path.name, sheet)
        n += 1
    print(f"사람 정답 대응 채점지 {n}개")
    return 0


def cmd_detail2(out: Path) -> int:
    first = score_detail(out, "detail")
    second = score_detail(out, "detail2")
    summary = {grp: {**first["summary"].get(grp, {}), **second["summary"].get(grp, {})}
               for grp in ("all", "visible")}
    human = {}
    if (out / "gold/dev_gold_human.csv").exists():
        h1 = score_detail(out, "detail", basis="human")
        h2 = score_detail(out, "detail2", basis="human")
        human = {grp: {**h1["summary"].get(grp, {}), **h2["summary"].get(grp, {})} for grp in ("all", "visible")}
        human["ungraded_sheets"] = h1["ungraded_sheets"] + h2["ungraded_sheets"]
    overhead = 4440 - 60  # 2026-11-24 빈 지시문 시험 호출(입력 4,440토큰, 지시문 약 60토큰)
    costs = {v: cost_estimate(s["avg_tokens_in"], s["avg_tokens_out"], overhead) for v, s in summary["all"].items()}
    base = costs.get("A", {}).get("krw_off_peak") or 0
    for v, c in costs.items():
        c["vs_A"] = round(c["krw_off_peak"] / base, 2) if base else None
        c["over_2x"] = bool(base) and c["krw_off_peak"] > 2 * base
    result = {"summary": summary, "summary_human_gold": human, "costs": costs,
              "grader_agreement": grader_agreement(out),
              "ungraded_sheets": second["ungraded_sheets"]}
    write_json(out / "scores/detail2.json", result)
    print(json.dumps(result, ensure_ascii=False, indent=1))
    return 0


def cmd_detail3(out: Path) -> int:
    """§17: D3·D4를 A·G·D1과 나란히. 정답 기준 둘(초안·사람)."""
    runs = {"detail": score_detail, "detail2": score_detail, "detail3": score_detail}
    result = {}
    for basis in ("human", "draft"):
        merged = {"all": {}, "visible": {}}
        ungraded = []
        for name in runs:
            r = score_detail(out, name, basis=basis)
            ungraded += [f"{name}:{s}" for s in r["ungraded_sheets"]]
            for grp in merged:
                merged[grp].update(r["summary"].get(grp, {}))
        result[basis] = {"summary": merged, "ungraded": ungraded}
    overhead = 4440 - 60
    s = result["human"]["summary"]["all"]
    costs = {v: cost_estimate(x["avg_tokens_in"], x["avg_tokens_out"], overhead) for v, x in s.items()}
    base = costs.get("D1", {}).get("krw_off_peak") or 0
    for c in costs.values():
        c["vs_D1"] = round(c["krw_off_peak"] / base, 2) if base else None
    result["costs_estimated"] = costs
    result["grader_agreement_D1"] = grader_agreement(out, "detail2", "detail3")
    write_json(out / "scores/detail3.json", result)
    print(json.dumps(result, ensure_ascii=False, indent=1))
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--data")
    ap.add_argument("cmd", choices=("detail-sheets", "detail", "external-sheets", "external", "detail2-sheets",
                                    "detail2", "detail-h-sheets", "detail3-sheets", "detail3"))
    args = ap.parse_args(argv)
    out = eval_dir(data_dir(args.data))
    if args.cmd == "detail3-sheets":  # D3·D4 + 공고 10건에 2차 D1을 섞어 다시 채점
        return cmd_detail_sheets(out, variants=("D3", "D4"), sheets_name="detail3", regrade=("D1",))
    if args.cmd == "detail3":
        return cmd_detail3(out)
    if args.cmd == "detail-h-sheets":
        return cmd_detail_h_sheets(out)
    if args.cmd == "detail2-sheets":  # D1·D2 + 공고 10건에 1차 A·G를 섞어 다시 채점
        return cmd_detail_sheets(out, variants=("D1", "D2"), sheets_name="detail2", regrade=("A", "G"))
    return {"detail-sheets": cmd_detail_sheets, "detail": cmd_detail, "external-sheets": cmd_external_sheets,
            "external": cmd_external, "detail2": cmd_detail2}[args.cmd](out)


if __name__ == "__main__":
    sys.exit(main())
