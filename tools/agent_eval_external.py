"""품질 평가 3단계: 외부 공고 찾기 기준선 실행과 결과 페이지 가져오기 (agent-quality-eval-spec §6.2·§6.3·§6.6).

실행(저장소 루트, worktree의 .venv 파이썬 + PYTHONPATH=.)
  python tools/agent_eval_external.py --data <메인>/data/local run --fake    # 가짜 제공자로 흐름만(runs_fake)
  python tools/agent_eval_external.py --data <메인>/data/local run           # DeepSeek API(유료, 상한 300원)
  python tools/agent_eval_external.py --data <메인>/data/local fetch         # 결과 링크 본문 가져오기(표준 라이브러리)

run
- 운영과 같은 흐름: build_search_messages → web_search → ground_items → read_pages → judge_items. 크레딧·저장소는 거치지 않음
- 기준선: 고치며 볼 12개를 한 번씩 + 분류마다 첫 질의(4개)를 두 번 더 = 20회. 회차마다 바로 저장, 다시 실행하면 빠진 것만
- 예산: 누적 비용이 상한(300원)을 넘을 호출은 하지 않고 멈춘다. 첫 2회 평균이 요청당 7원을 넘으면 반복 실행(2·3회차)을 뺀다
- 시간: 평일 한국 시간 10~13시·15~19시(2배 요금)에는 돌리지 않는다
- 키는 harness_check.api_key()로 읽고 출력·저장하지 않는다

fetch
- 결과 링크를 한 번씩 GET. 같은 사이트는 3초 간격, robots.txt가 막은 경로는 가져오지 않음
- 상태: ok / robots / http_<코드> / error / empty / login. 본문은 <data>/agent_eval/pages/에만 둔다
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
import sys
import time
import urllib.error
import urllib.request
import urllib.robotparser
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from backend.agent import llm  # noqa: E402
from backend.agent.external import (  # noqa: E402
    EXTERNAL_VERSION, READ_PROMPT, build_read_message, build_search_messages, ground_items, judge_items,
)
from tools.agent_eval_common import data_dir, eval_dir, query_request, read_json, write_json  # noqa: E402

KST = timezone(timedelta(hours=9))
CAP_KRW = 300.0
UNIT_LIMIT_KRW = 7.0
EST_PER_RUN_KRW = 7.0  # 다음 호출이 상한을 넘을지 볼 때 쓰는 보수적 추정
REPEATS = 2  # 반복 실행 추가 횟수
UA = "Mozilla/5.0 (compatible; GwittimEval/0.1; quality evaluation, one request per page)"
PEAK_KST = (range(10, 13), range(15, 19))


def is_peak(now: datetime) -> bool:
    k = now.astimezone(KST)
    return k.weekday() < 5 and any(k.hour in r for r in PEAK_KST)


def plan(queries: list[dict]) -> list[dict]:
    """(질의, 회차) 목록. 회차 1은 dev 12개 전부, 2·3은 분류마다 첫 질의."""
    dev = [q for q in queries if q["split"] == "dev"]
    first = {}
    for q in dev:
        first.setdefault(q["category"], q["id"])
    runs = [{"qid": q["id"], "rep": 1} for q in dev]
    runs += [{"qid": qid, "rep": rep} for rep in range(2, 2 + REPEATS) for qid in first.values()]
    return runs


def run_query(q: dict, provider, today: date) -> dict:
    prof, body = query_request(q)
    system, user = build_search_messages(prof, body, today)
    rec = {"qid": q["id"], "query": q, "today": today.isoformat(), "external_version": EXTERNAL_VERSION,
           "user": user, "started_at": datetime.now(KST).isoformat(timespec="seconds")}
    try:
        search = provider.web_search(system, user)
    except Exception as exc:
        usage = getattr(exc, "usage", None)
        rec.update({"error": f"search {type(exc).__name__}", "cost": {"search": usage.cost_krw if usage else None}})
        return rec
    items, gstats = ground_items(search.text, search.sources, today)
    rec["search"] = {"text": search.text, "sources": search.sources, "tokens": [search.usage.input_tokens,
                     search.usage.output_tokens], "seconds": round(search.usage.elapsed_seconds, 1),
                     "cost": search.usage.cost_krw}
    rec["grounded"] = {"items": items, "stats": gstats}
    cost = {"search": search.usage.cost_krw or 0.0, "read": 0.0}
    final = [{**i, "verdict": None, "target": None, "organizer": None, "read": False} for i in items]
    if items and hasattr(provider, "read_pages"):
        try:
            read = provider.read_pages(READ_PROMPT, build_read_message(items))
            cost["read"] = read.usage.cost_krw or 0.0
            final, jstats = judge_items(items, read.text, read.read_urls, prof, today)
            rec["read"] = {"text": read.text, "read_urls": read.read_urls, "stats": jstats,
                           "tokens": [read.usage.input_tokens, read.usage.output_tokens],
                           "seconds": round(read.usage.elapsed_seconds, 1), "cost": read.usage.cost_krw}
        except Exception as exc:
            usage = getattr(exc, "usage", None)
            cost["read"] = (usage.cost_krw or 0.0) if usage else 0.0
            rec["read"] = {"error": type(exc).__name__}
    rec.update({"final": final, "charged": bool(final), "cost": cost, "cost_total": round(sum(cost.values()), 2),
                "seconds_total": round(rec["search"]["seconds"] + (rec.get("read") or {}).get("seconds", 0), 1)})
    return rec


def cmd_run(out: Path, fake: bool, today: date) -> int:
    queries = {q["id"]: q for q in read_json(out / "queries.json")}
    base = out / ("runs_fake" if fake else "runs") / "external"
    base.mkdir(parents=True, exist_ok=True)
    if fake:
        provider = llm.FakeProvider(env={})
    else:
        from tools.harness_check import api_key

        key = api_key()
        if not key:
            print("DEEPSEEK_API_KEY가 없어 실행하지 않습니다")
            return 2
        provider = llm.DeepSeekProvider(env={"DEEPSEEK_API_KEY": key})
    runs = plan(list(queries.values()))
    spent = sum((read_json(p).get("cost_total") or 0.0) for p in base.glob("*.json"))
    done = []
    for r in runs:
        path = base / f"{r['qid']}_r{r['rep']}.json"
        if path.exists() and "error" not in read_json(path):
            done.append(read_json(path))
            continue
        if r["rep"] > 1 and not fake:
            costs = [d["cost_total"] for d in done if d.get("cost_total") is not None]
            if len(costs) >= 2 and sum(costs[:2]) / 2 > UNIT_LIMIT_KRW:
                print(f"요청당 {sum(costs[:2]) / 2:.1f}원 > {UNIT_LIMIT_KRW}원: 반복 실행을 뺀다")
                break
        if not fake and is_peak(datetime.now(KST)):
            print("평일 할증 시간대라 멈춥니다(다시 실행하면 이어서 돎)")
            return 3
        if not fake and spent + EST_PER_RUN_KRW > CAP_KRW:
            print(f"누적 {spent:.1f}원: 다음 호출이 상한 {CAP_KRW}원을 넘을 수 있어 멈춥니다")
            return 4
        rec = run_query(queries[r["qid"]], provider, today)
        rec["rep"] = r["rep"]
        write_json(path, rec)
        spent += rec.get("cost_total") or (rec.get("cost") or {}).get("search") or 0.0
        done.append(rec)
        n = len(rec.get("final") or [])
        print(f"{r['qid']} r{r['rep']}: 결과 {n}개, {rec.get('cost_total')}원, {rec.get('seconds_total')}초"
              + (f" 오류 {rec['error']}" if "error" in rec else "") + f" (누적 {spent:.1f}원)", flush=True)
    print(f"끝. 누적 {spent:.1f}원")
    return 0


# ---------- fetch ----------

_TAG = re.compile(r"<(script|style|noscript)\b.*?</\1>|<[^>]+>", re.S | re.I)
_WS = re.compile(r"[ \t\r\f\v]+")
_LOGIN = re.compile(r"로그인이 필요|로그인 후 이용|login required|please log in", re.I)


def html_text(raw: str) -> str:
    text = html.unescape(_TAG.sub("\n", raw))
    lines = [_WS.sub(" ", ln).strip() for ln in text.split("\n")]
    return "\n".join(ln for ln in lines if ln)


def _charset(resp, data: bytes) -> str:
    cs = resp.headers.get_content_charset()
    if not cs:
        m = re.search(rb"charset=[\"']?([A-Za-z0-9_-]+)", data[:4000])
        cs = m.group(1).decode() if m else "utf-8"
    return cs


UNVERIFIABLE = ("login", "robots")  # 서버가 본문을 못 봤지만 사람이 브라우저로 열 수 있는 것: '확인 못 함'(§16.3)
BROKEN = ("redirected", "error", "empty")  # 안 열림. http_* 도 안 열림


def redirected_home(url: str, final: str | None) -> bool:
    """공고 주소가 사이트 첫 화면으로 넘어갔는지(경로가 있던 주소의 최종 경로가 '/' 또는 빈 것, 질의도 없음)."""
    if not final:
        return False
    a, b = urlsplit(url), urlsplit(final)
    return a.path.strip("/") != "" and b.path.strip("/") == "" and not b.query


def open_state(status: str | None) -> str:
    """가져오기 상태 -> opened / unverifiable / broken / not_fetched."""
    if status is None:
        return "not_fetched"
    if status == "ok":
        return "opened"
    if status in UNVERIFIABLE:
        return "unverifiable"
    return "broken"


def cmd_reclassify(out: Path) -> int:
    """저장된 색인의 최종 주소로 '넘어감'을 다시 판정한다(다시 가져오지 않음)."""
    path = out / "pages/index.json"
    index = read_json(path)
    changed = 0
    for url, rec in index.items():
        if rec.get("status") == "ok" and redirected_home(url, rec.get("final_url")):
            rec["status"], rec["status_was"] = "redirected", "ok"
            changed += 1
    write_json(path, index)
    print(f"넘어감으로 바꾼 주소 {changed}개")
    return 0


def fetch_one(url: str, robots: dict, last_hit: dict) -> dict:
    parts = urlsplit(url)
    host = f"{parts.scheme}://{parts.netloc}"
    if host not in robots:
        rp = urllib.robotparser.RobotFileParser()
        try:
            req = urllib.request.Request(host + "/robots.txt", headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=15) as resp:
                rp.parse(resp.read().decode("utf-8", "replace").splitlines())
        except Exception:
            rp.parse([])  # robots.txt가 없거나 못 읽으면 막지 않은 것으로 본다
        robots[host] = rp
    if not robots[host].can_fetch(UA, url):
        return {"url": url, "status": "robots"}
    wait = 3.0 - (time.monotonic() - last_hit.get(host, -10.0))
    if wait > 0:
        time.sleep(wait)
    last_hit[host] = time.monotonic()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "ko,en;q=0.8"})
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = resp.read(3_000_000)
            final = resp.geturl()
            text = html_text(data.decode(_charset(resp, data), "replace"))
    except urllib.error.HTTPError as exc:
        return {"url": url, "status": f"http_{exc.code}"}
    except Exception as exc:
        return {"url": url, "status": "error", "error": type(exc).__name__}
    status = "ok"
    if redirected_home(url, final):
        status = "redirected"
    elif len(text) < 200:
        status = "empty"
    elif _LOGIN.search(text) and len(text) < 3000:
        status = "login"
    return {"url": url, "final_url": final, "status": status, "chars": len(text), "text": text}


def cmd_fetch(out: Path) -> int:
    base = out / "runs" / "external"
    pages = out / "pages"
    pages.mkdir(parents=True, exist_ok=True)
    index_path = pages / "index.json"
    index = read_json(index_path) if index_path.exists() else {}
    urls = []
    for p in sorted(base.glob("*.json")):
        rec = read_json(p)
        for i in rec.get("final") or []:
            if i["url"] not in urls:
                urls.append(i["url"])
    robots, last_hit = {}, {}
    for url in urls:
        if url in index:
            continue
        res = fetch_one(url, robots, last_hit)
        name = hashlib.sha256(url.encode()).hexdigest()[:16]
        if "text" in res:
            (pages / f"{name}.txt").write_text(res.pop("text"), encoding="utf-8")
            res["file"] = f"{name}.txt"
        res["fetched_at"] = datetime.now(KST).isoformat(timespec="seconds")
        index[url] = res
        write_json(index_path, index)
        print(f"{res['status']:8} {url[:90]}", flush=True)
    print(f"끝: 링크 {len(urls)}개")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--data")
    ap.add_argument("cmd", choices=("run", "fetch", "reclassify"))
    ap.add_argument("--fake", action="store_true")
    ap.add_argument("--today", type=date.fromisoformat, default=None, help="기본: 오늘(한국 날짜)")
    args = ap.parse_args(argv)
    out = eval_dir(data_dir(args.data))
    if args.cmd == "run":
        return cmd_run(out, args.fake, args.today or datetime.now(KST).date())
    return cmd_reclassify(out) if args.cmd == "reclassify" else cmd_fetch(out)


if __name__ == "__main__":
    sys.exit(main())
