"""게시판 공고 정답표(가림 표)를 만든다.

입력: data/local/notices.json 의 게시판 4개(mjc_www_*) 공고
출력: data/local/gold/board_sheet_A.csv, board_sheet_B.csv (utf-8-sig), board_guide.txt

- 게시판별 비례 100건: 공지 34, 채용 34, 장학 20, 근로 12. 씨앗 0. 모자라면 있는 만큼 뽑고 알린다.
- 열: notice_id, 게시판, 제목, source_url, 그리고 빈 정답 칸(마감일, 학교, 학과, 학년, 재학상태, 자유조건, 누구나, 메모).
- 요약·조건·마감일 같은 분석 결과는 넣지 않는다. 정답은 source_url의 원문과 포스터를 보고 적는다.
- 두 표는 같은 공고를 담고 행 순서만 다르다(A 씨앗 1, B 씨앗 2).
- 표나 안내 파일이 이미 있으면 덮어쓰지 않고 멈춘다.

실행: uv run python tools/make_board_gold_sheet.py [--notices PATH] [--out-dir DIR]
"""
from __future__ import annotations

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # python tools/x.py 로 돌릴 때 필요

from tools.board_gold_common import (  # noqa: E402
    BOARDS, COLUMNS, ENROLLMENT, GOLD_DIR, GRADES, NONE, NOTICES, UNKNOWN,
    dictionary_codes, load_notices, major_names, write_sheet,
)

QUOTA = {"mjc_www_notice": 34, "mjc_www_job": 34, "mjc_www_scholarship": 20, "mjc_www_work": 12}
SAMPLE_SEED = 0


def sample(notices: dict) -> tuple[list[dict], list[str]]:
    rng = random.Random(SAMPLE_SEED)
    picked: list[dict] = []
    alerts: list[str] = []
    for source_id, want in QUOTA.items():
        pool = sorted(k for k, v in notices.items() if v.get("source_id") == source_id)
        if len(pool) < want:
            alerts.append(f"{BOARDS[source_id]}({source_id}): {want}건 필요, {len(pool)}건뿐이라 전부 뽑음")
            chosen = pool
        else:
            chosen = rng.sample(pool, want)
        for key in chosen:
            n = notices[key]
            picked.append({
                "notice_id": key, "게시판": BOARDS[source_id],
                "제목": n.get("title") or "", "source_url": n.get("source_url") or "",
            })
    return picked, alerts


def guide_text() -> str:
    codes = dictionary_codes()
    names = major_names()
    lines = [
        "게시판 정답표 작성 안내",
        "",
        "정답은 source_url의 원문 페이지와 포스터를 보고 적는다. 분석 결과(요약·조건·마감일)는 보지 않는다.",
        "두 작업자가 서로의 표를 보지 않고 따로 채운다. 칸은 비우지 않는다(메모, 자유조건 제외).",
        "",
        "마감일",
        f"  YYYY-MM-DD, 마감일이 원문에 없으면 {NONE}, 원문으로 확정할 수 없으면 {UNKNOWN}.",
        "  시각은 적지 않는다. 선착순·예산 소진처럼 날짜가 없는 마감은 없음.",
        "",
        "학교 / 학과 / 학년 / 재학상태",
        f"  지원 자격으로 명시된 조건만 코드로 적는다. 여러 개는 공백으로 구분(그중 하나면 지원 가능), 조건이 없으면 {NONE}.",
        "  우대 사항은 지원 자격이 아니므로 구조 조건에 넣지 않고 자유조건에 적는다.",
        "",
        "  학교 코드: " + ", ".join(codes["학교"]),
        "  학과 코드:",
    ]
    lines += [f"    {c}  {names.get(c, '')}" for c in codes["학과"]]
    lines += [
        "  학년 코드: " + ", ".join(GRADES),
        "  재학상태 코드: " + ", ".join(ENROLLMENT) + "  (재학 enrolled, 휴학 on_leave, 졸업 graduated)",
        "",
        "자유조건",
        "  성적·소득·어학·연령·거주지·우대 등 위 코드로 적을 수 없는 조건을 한 줄에 하나, 원문 문구 그대로 적는다.",
        "  없으면 비워 둔다.",
        "",
        "누구나",
        "  Y 또는 N. 원문이 재학생 누구나 지원 가능하다고 하고 다른 제한이 없으면 Y.",
        "",
        "메모: 자유롭게.",
        "",
    ]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--notices", type=Path, default=NOTICES)
    ap.add_argument("--out-dir", type=Path, default=GOLD_DIR)
    args = ap.parse_args(argv)

    out = args.out_dir
    targets = [out / "board_sheet_A.csv", out / "board_sheet_B.csv", out / "board_guide.txt"]
    existing = [t for t in targets if t.exists()]
    if existing:
        print("이미 있는 파일이 있어 멈춤(덮어쓰지 않음): " + ", ".join(str(t) for t in existing), file=sys.stderr)
        return 1
    if not args.notices.exists():
        print(f"입력 없음: {args.notices}", file=sys.stderr)
        return 1

    rows, alerts = sample(load_notices(args.notices))
    out.mkdir(parents=True, exist_ok=True)
    for path, seed in ((targets[0], 1), (targets[1], 2)):
        shuffled = list(rows)
        random.Random(seed).shuffle(shuffled)
        write_sheet(path, [{**{c: "" for c in COLUMNS}, **r} for r in shuffled])
    targets[2].write_text(guide_text(), encoding="utf-8")

    counts = {name: sum(1 for r in rows if r["게시판"] == name) for name in BOARDS.values()}
    print(f"표본 {len(rows)}건 {counts}")
    for a in alerts:
        print("알림: " + a)
    print("출력: " + ", ".join(str(t) for t in targets))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
