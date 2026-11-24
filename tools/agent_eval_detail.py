"""품질 평가 2단계: 상세 분석 A(지금 방식)·G(일반 AI 기준선)를 표본에 돌려 저장한다 (agent-quality-eval-spec §5.4·§5.6).

실행(저장소 루트, worktree의 .venv 파이썬 + PYTHONPATH=.)
  python tools/agent_eval_detail.py --data <메인>/data/local --fake          # 가짜 제공자로 흐름만 확인(저장 위치 runs_fake)
  python tools/agent_eval_detail.py --data <메인>/data/local                 # opencode 구독(0원), split=dev
  python tools/agent_eval_detail.py --data <메인>/data/local --split holdout # 최종 측정 때만

- A: build_messages(공고, 프로필, 서버 판정, 기준 날짜) + detail_analysis.md + 운영 후처리(scrub_codes → split_long_lines → ground_report)
- G: 프로필 + 제목 + 본문 전체. 4칸 이름과 줄 수만 알려 주고 판정·귀띔 지침·후처리 없음. 오늘 날짜는 지시문에 적는다
- 기준 날짜는 sample/eval_dates.json(공고 게시일)에서 읽는다(§5.1)
- 저장: <data>/agent_eval/runs/detail/<방식>/<공고 키>__<프로필>.json. 입력이 같으면 다시 부르지 않는다(입력 해시 비교).
  끊겨도 다시 실행하면 빠진 것만 돈다
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from backend.agent import llm  # noqa: E402
from backend.agent.payload import build_payload  # noqa: E402
from backend.agent.prompt import (  # noqa: E402
    HARNESS_VERSION, SYSTEM_PROMPT, _student, body_for_model, build_messages, deadline_passed, ground_report, scrub_codes,
    split_long_lines,
)
from backend.recommendation import evaluate  # noqa: E402
from tools.agent_eval_common import PROFILE_NAMES, data_dir, eval_dir, profile, read_json, school_of, write_json  # noqa: E402
from tools.agent_eval_prep import today_map  # noqa: E402
from tools.agent_eval_sample import body_of  # noqa: E402
from tools.harness_check import check  # noqa: E402

G_SYSTEM = """당신은 대학생을 돕는 도우미입니다. 아래 학생 정보와 공고 원문을 읽고, 이 학생 기준으로 공고를 정리해 주십시오. 오늘은 {today}입니다.
JSON 객체 하나만 출력합니다. 칸은 4개입니다.
- "fit": 나와 이 공고 (최대 2줄)
- "eligibility": 지원 자격 (1~3줄)
- "todo": 지원 전 할 일 (1~2줄)
- "skills": 필요한 역량 (최대 4줄)
값은 한국어 문자열이고, 줄은 \\n으로 나눕니다."""

VARIANTS = ("A", "G")


def build_a(notice: dict, prof: dict, chips: dict, today: date) -> tuple[str, str, str]:
    verdict = evaluate(notice["eligibility"], prof)
    system, user = build_messages(notice, build_payload(prof, chips), verdict, today)
    return system, user, verdict[0]


def build_g(notice: dict, record: dict, prof: dict, chips: dict, today: date) -> tuple[str, str]:
    material = {"학생": _student(build_payload(prof, chips)),
                "공고": {"제목": notice["title"], "본문": body_of(record).strip()}}
    return G_SYSTEM.format(today=today.isoformat()), json.dumps(material, ensure_ascii=False, indent=1)


def input_hash(system: str, user: str) -> str:
    return hashlib.sha256(f"{system}\n\x00\n{user}".encode()).hexdigest()[:16]


def jobs(rows: list[dict], notices: dict, records: dict, todays: dict[str, date], variants=VARIANTS) -> list[dict]:
    out = []
    for r in rows:
        notice, today = notices[r["key"]], todays[r["key"]]
        for pname in PROFILE_NAMES:
            prof, chips = profile(pname, school_of(r["group"]))
            for v in variants:
                if v == "A":
                    system, user, verdict = build_a(notice, prof, chips, today)
                elif v in ("D1", "D2", "D3", "D4"):
                    from tools import agent_eval_variants as ev

                    system, user, verdict = ev.build(v, notice, records[r["key"]], prof, chips, today)
                elif v in ("P", "P0"):  # 운영 코드 경로(본문 반영 뒤). P0은 본문 없이(저장 전·본문 없는 공고)
                    verdict_t = evaluate(notice["eligibility"], prof)
                    body = body_of(records[r["key"]]).strip() if v == "P" else None
                    system, user = build_messages(notice, build_payload(prof, chips), verdict_t, today, body=body)
                    verdict = verdict_t[0]
                else:
                    system, user = build_g(notice, records[r["key"]], prof, chips, today)
                    verdict = evaluate(notice["eligibility"], prof)[0]  # 채점용. G에는 보내지 않는다
                out.append({"variant": v, "key": r["key"], "profile": pname, "today": today.isoformat(),
                            "verdict": verdict, "system": system, "user": user, "hash": input_hash(system, user)})
    return out


def run_one(job: dict, notice: dict, provider, retries: int = 2, record: dict | None = None) -> dict:
    """호출 한 번 + 후처리(A: 운영, D1·D2: tools/agent_eval_variants, G: 없음). 실패도 기록한다."""
    rec = {k: job[k] for k in ("variant", "key", "profile", "today", "verdict", "hash")}
    rec["harness_version"] = {"A": HARNESS_VERSION, "P": HARNESS_VERSION, "P0": HARNESS_VERSION, "D1": "eval-d1",
                              "D2": "eval-d2", "D3": "eval-d3", "D4": "eval-d4"}.get(job["variant"])
    rec["system_sha"] = hashlib.sha256(job["system"].encode()).hexdigest()[:16]
    rec["user"] = job["user"]
    last = None
    for attempt in range(retries + 1):
        try:
            res = provider.generate(job["system"], job["user"], notice_id=job["key"])
            break
        except (Exception, SystemExit) as exc:  # OpencodeProvider는 실패를 SystemExit로 낸다
            last = f"{type(exc).__name__}: {exc}"
            time.sleep(2 * (attempt + 1))
    else:
        rec["error"] = last
        return rec
    today = date.fromisoformat(job["today"])
    raw = res.report
    rec.update({"raw": raw, "tokens": [res.usage.input_tokens, res.usage.output_tokens],
                "seconds": round(res.usage.elapsed_seconds, 1), "provider": res.usage.provider, "attempts": attempt + 1})
    if job["variant"] == "A":
        report, scrubbed = scrub_codes(raw)
        report, split = split_long_lines(report)
        report, grounded = ground_report(report, notice, job["verdict"], today)
        rec.update({"report": report, "post": {"scrubbed": scrubbed, "split": split, "grounded": grounded}})
    elif job["variant"] in ("P", "P0"):  # 운영 후처리 그대로(service.py와 같은 순서)
        body = body_for_model(body_of(record).strip())[0] if job["variant"] == "P" else None
        report, scrubbed = scrub_codes(raw)
        report, split = split_long_lines(report)
        report, grounded = ground_report(report, notice, job["verdict"], today, body=body)
        rec.update({"report": report, "post": {"scrubbed": scrubbed, "split": split, "grounded": grounded}})
    elif job["variant"] in ("D1", "D2", "D3", "D4"):
        from tools import agent_eval_variants as ev

        report, post = ev.postprocess(job["variant"], raw, notice, record, job["verdict"], today)
        rec.update({"report": report, "post": post})
        scrubbed = post["scrubbed"]
    else:
        report, scrubbed = scrub_codes(raw)  # 집계만. G 결과는 바꾸지 않는다
        rec.update({"report": raw, "post": {"scrubbed_would_be": scrubbed}})
        scrubbed, split = scrubbed, 0
    quality, form = check(rec["report"], scrubbed if job["variant"] != "G" else 0, rec["post"].get("split", 0),
                          job["verdict"], deadline_passed(notice, today))
    rec.update({"quality": quality, "format": form})
    return rec


def out_path(base: Path, job: dict) -> Path:
    return base / job["variant"] / f"{job['key'].replace(':', '__')}__{job['profile']}.json"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--data")
    ap.add_argument("--split", choices=("dev", "holdout"), default="dev")
    ap.add_argument("--variants", nargs="*", default=list(VARIANTS), choices=("A", "G", "D1", "D2", "D3", "D4", "P", "P0"))
    ap.add_argument("--fake", action="store_true", help="가짜 제공자(runs_fake/에 저장)")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--limit", type=int, help="이번에 돌릴 최대 호출 수")
    ap.add_argument("--keys-json", type=Path, help="이 JSON의 keys 목록에 있는 공고만(예: gold/human_dev.json)")
    args = ap.parse_args(argv)
    out = eval_dir(data_dir(args.data))
    manifest = read_json(out / "sample/manifest.json")
    rows = [r for r in manifest["sample"] if r["split"] == args.split]
    if args.keys_json:
        keep = set(read_json(args.keys_json)["keys"])
        rows = [r for r in rows if r["key"] in keep]
    notices, records = read_json(out / "sample/notices.json"), read_json(out / "sample/records.json")
    todo = jobs(rows, notices, records, today_map(out.parent), args.variants)
    base = out / ("runs_fake" if args.fake else "runs") / "detail"
    if args.fake:
        provider = llm.FakeProvider(env={})
    else:
        from tools.harness_check import OpencodeProvider
        provider = OpencodeProvider()
    pending = []
    for j in todo:
        p = out_path(base, j)
        if p.exists():
            old = read_json(p)
            if old.get("hash") == j["hash"] and "error" not in old:
                continue
        pending.append(j)
    if args.limit:
        pending = pending[: args.limit]
    print(f"전체 {len(todo)}회, 저장됨 {len(todo) - len(pending)}회, 이번 {len(pending)}회", flush=True)
    done = errors = 0
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(run_one, j, notices[j["key"]], provider, 2, records[j["key"]]): j for j in pending}
        for f in as_completed(futs):
            j = futs[f]
            rec = f.result()
            write_json(out_path(base, j), rec)  # 호출마다 바로 저장
            done += 1
            errors += "error" in rec
            print(f"[{done}/{len(pending)}] {j['variant']} {j['key']} {j['profile']} "
                  f"{'오류 ' + rec['error'][:60] if 'error' in rec else str(rec.get('seconds')) + '초'}", flush=True)
    print(f"끝: {done}회, 오류 {errors}회")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
