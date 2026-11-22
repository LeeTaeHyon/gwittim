"""상세 분석 지침(하네스) 시험: 고정 공고 몇 건을 실제 DeepSeek로 돌려 리포트와 형식 위반을 보인다.

지침(`backend/agent/harness/detail_analysis.md`)을 고친 뒤 PR 전에 돌린다. 비교할 지침 파일을 하나 더 주면 나란히 본다.

실행(저장소 루트)
  uv run python tools/harness_check.py                         # 지금 지침
  uv run python tools/harness_check.py --compare old.md        # 지금 지침 vs old.md
  uv run python tools/harness_check.py --harness new.md        # 다른 지침 파일만

- 키: 환경변수 DEEPSEEK_API_KEY. 없으면(Windows) 사용자 환경변수 레지스트리에서 읽는다. 키는 출력하지 않는다
- 공고: data/local/notices.json(git 제외)의 실제 공고. 학생은 합성 프로필
- 결과: data/local/harness_check/<시각>.md (git 제외). 공고 1건당 약 0.5~1원
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import date, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from backend.agent import llm  # noqa: E402
from backend.agent.payload import build_payload  # noqa: E402
from backend.agent.prompt import (  # noqa: E402
    HARNESS_FILE, HARNESS_VERSION, build_messages, load_harness, scrub_codes, split_long_lines,
)
from backend.recommendation import evaluate  # noqa: E402

NOTICES = ROOT / "data/local/notices.json"
OUT = ROOT / "data/local/harness_check"
# 판정이 서로 다른 공고(불충족·확인 필요)와 분류가 다른 공고를 섞었다 (2026-11-22 확인에 쓴 3건)
DEFAULT_IDS = ["mjc_www_job:BD0000003213", "mjc_www_notice:BD0050390093", "mjc_www_job:BD0000003194"]
PROFILE = {"university_id": "mjc", "major_id": "mjc.computer_engineering", "grade": 2, "enrollment_status": "enrolled",
           "interest_ids": ["software", "ai_data"], "target_role_ids": ["software_developer"]}
CHIPS = {"experience": ["python", "team_project"], "period": "vacation", "regions": ["seoul"]}

PLAIN_ENDING = re.compile(r"(?:한다|이다|있다|없다|된다|않다)[.]")  # 평서형
STRETCH = re.compile(r"방학에만|학기 중에만|주말에만")  # 학생이 고른 시기를 넓히거나 좁힘
KEY_ECHO = re.compile(r"참고 사항|조건을 모두 찾았는지|구분이|조건별 결과|원문에서 확인할 조건")
FIT_TAG = re.compile(r"^(맞음|안 맞음|확인 필요)\s*[:：]")
VERDICT_LINE = re.compile(r"^(충족|미충족|확인 필요)\s*[:：]")
# 판정 낱말 읽기: 새 형식 '미충족: …', 예전 형식 '판정: 불충족 …' 둘 다
VERDICT_WORD = re.compile(r"^(?:판정\s*[:：]\s*)?(충족|미충족|불충족|확인 필요)")
SERVER_VERDICT = {"met": "충족", "not_met": "미충족", "needs_check": "확인 필요"}
SKILLS_UNKNOWN = "요구 역량을 확인하기 어렵습니다"
MAX_LINES = {"fit": 2, "eligibility": 3, "todo": 2, "skills": 4}  # 지금 지침의 칸별 줄 수


def report_verdict(report: dict) -> str | None:
    """eligibility 첫 줄의 판정 낱말(충족 / 미충족 / 확인 필요). 없으면 None. '불충족'은 '미충족'으로."""
    first = str(report.get("eligibility", "")).strip().split("\n")[0].strip()
    m = VERDICT_WORD.match(first)
    if not m:
        return None
    return "미충족" if m.group(1) == "불충족" else m.group(1)


def check(report: dict, scrubbed: int, split: int, verdict: str | None = None,
          deadline_passed: bool = False) -> tuple[list[str], list[str]]:
    """(품질 오류, 형식 점검).

    - 품질 오류: 지침이 바뀌어도 늘 지켜야 하는 것. 서버 판정과 리포트 판정 일치, 영어 코드, 평서형, 입력 칸 이름 옮김,
      미충족인데 지원서 작성 권함
    - 형식 점검: 지금 지침의 출력 형식(칸별 줄 수, 줄 길이, 꼬리표, 첫 줄 모양, 긴 문단 나눔). 이전 지침과 비교할 때는
      이전 지침 쪽 형식 점검을 오류로 세지 않고 참고로만 보인다
    """
    quality, form = [], []
    expected = SERVER_VERDICT.get(verdict or "")
    got = report_verdict(report)
    if expected and got is None:
        quality.append(f"판정 낱말 없음(서버 {expected})")
    elif expected and got != expected:
        quality.append(f"판정 불일치(서버 {expected}, 리포트 {got})")
    if scrubbed:
        quality.append(f"영어 코드 {scrubbed}곳 치환")
    text = "\n".join(v for v in report.values() if isinstance(v, str))
    if PLAIN_ENDING.search(text):
        quality.append("평서형(~한다)")
    if KEY_ECHO.search(text):
        quality.append("입력 칸 이름 옮김")
    if (verdict == "not_met" or deadline_passed) and "지원서" in str(report.get("todo", "")):
        quality.append("미충족·마감 지남인데 지원서 작성 권함")
    if STRETCH.search(text):
        quality.append("학생 선택값 넓힘(…에만)")

    if split:
        form.append(f"긴 문단 {split}곳 나눔")
    for k, v in report.items():
        lines = [ln for ln in str(v).split("\n") if ln.strip()]
        if not 1 <= len(lines) <= MAX_LINES.get(k, 5):
            form.append(f"{k}: 줄 {len(lines)}개")
        if any(len(ln) > 90 for ln in lines):
            form.append(f"{k}: 90자 넘는 줄")
    fit = [ln for ln in str(report.get("fit", "")).split("\n") if ln.strip()]
    if fit and not all(FIT_TAG.match(ln) for ln in fit):
        form.append("fit: 꼬리표 없는 줄")
    skills = [ln for ln in str(report.get("skills", "")).split("\n") if ln.strip()]
    if any(len(ln) > 20 for ln in skills) and not any(SKILLS_UNKNOWN in ln for ln in skills):
        form.append("skills: 20자 넘는 줄(앱이 칩으로 못 보임)")
    if deadline_passed and fit and "마감" not in fit[0]:
        form.append("fit: 마감이 지났는데 첫 줄이 마감이 아님")
    first = str(report.get("eligibility", "")).split("\n")[0]
    if not VERDICT_LINE.match(first):
        form.append("eligibility: 첫 줄이 '충족:/미충족:/확인 필요:' 아님")
    return quality, form


def violations(report: dict, scrubbed: int, split: int, verdict: str | None = None) -> list[str]:
    """품질 오류 + 형식 점검을 한 목록으로 (지금 지침 기준)."""
    quality, form = check(report, scrubbed, split, verdict)
    return quality + form


def api_key() -> str:
    key = os.environ.get("DEEPSEEK_API_KEY", "").strip()
    if key or os.name != "nt":
        return key
    import winreg  # 새 터미널을 열기 전에도 쓸 수 있게(사용자 환경변수)

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as k:
            return winreg.QueryValueEx(k, "DEEPSEEK_API_KEY")[0].strip()
    except OSError:
        return ""


def notice_verdict(notice: dict) -> str:
    return evaluate(notice["eligibility"], PROFILE)[0]


def run(system: str, notice: dict, provider, today: date) -> dict:
    verdict = evaluate(notice["eligibility"], PROFILE)
    _, user = build_messages(notice, build_payload(PROFILE, CHIPS), verdict, today)
    res = provider.generate(system, user, notice_id=notice["notice_id"])
    report, scrubbed = scrub_codes(res.report)
    report, split = split_long_lines(report)
    dl = notice.get("application_deadline") or {}
    passed = bool(dl.get("date")) and dl["date"] < today.isoformat()
    quality, form = check(report, scrubbed, split, verdict[0], passed)
    return {"report": report, "quality": quality, "format": form, "verdict": verdict[0],
            "tokens": (res.usage.input_tokens, res.usage.output_tokens), "cost": res.usage.cost_krw,
            "seconds": round(res.usage.elapsed_seconds, 1)}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--harness", type=Path, default=HARNESS_FILE, help="시험할 지침 파일 (기본: 지금 지침)")
    ap.add_argument("--compare", type=Path, help="나란히 볼 다른 지침 파일")
    ap.add_argument("--ids", nargs="*", default=DEFAULT_IDS)
    args = ap.parse_args(argv)
    key = api_key()
    if not key:
        print("DEEPSEEK_API_KEY가 없어 실행하지 않습니다.")
        return 2
    notices = json.loads(NOTICES.read_text(encoding="utf-8"))
    provider = llm.DeepSeekProvider(env={"DEEPSEEK_API_KEY": key})
    today = date.today()
    # (이름, 지침, 지금 형식으로 채점하는지). 비교용 이전 지침은 형식 점검을 참고로만 센다
    sets = [(args.harness.name, load_harness(args.harness), True)]
    if args.compare:
        sets.append((args.compare.name, load_harness(args.compare), False))
    tally = {name: {"quality": 0, "format": 0} for name, _, _ in sets}
    lines = [f"# 지침 시험 {datetime.now():%Y-%m-%d %H:%M}", "", f"- 지금 지침 버전: `{HARNESS_VERSION}`",
             f"- 비교: {' vs '.join(n for n, _, _ in sets)}", ""]
    total = 0.0
    for nid in args.ids:
        notice = notices[nid]
        lines += [f"## {notice['title']}", ""]
        lines.append(f"서버 판정: {SERVER_VERDICT.get(notice_verdict(notice), '?')}")
        lines.append("")
        for name, system, current in sets:
            r = run(system, notice, provider, today)
            total += r["cost"] or 0
            q = ", ".join(r["quality"]) or "없음"
            f = ", ".join(r["format"]) or "없음"
            tally[name]["quality"] += len(r["quality"])
            if current:
                tally[name]["format"] += len(r["format"])
            form_label = "형식" if current else "형식(참고, 이전 지침이라 세지 않음)"
            head = (f"### {name} — 품질 오류: {q} · {form_label}: {f} · "
                    f"토큰 {r['tokens'][0]}/{r['tokens'][1]} · {r['cost']}원 · {r['seconds']}초")
            print(f"[{nid}] {name}: 품질 {q} / {form_label} {f}")
            lines += [head, ""] + [f"**{k}**\n{v}\n" for k, v in r["report"].items()]
    lines.append("\n## 합계")
    for name, t in tally.items():
        lines.append(f"- {name}: 품질 오류 {t['quality']}건, 형식 점검 {t['format']}건")
        print(f"합계 {name}: 품질 오류 {t['quality']}건, 형식 점검 {t['format']}건")
    lines.append(f"- 비용 약 {round(total, 2)}원")
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{datetime.now():%Y%m%d_%H%M%S}.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    print(f"결과: {path} (합계 약 {round(total, 2)}원)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
