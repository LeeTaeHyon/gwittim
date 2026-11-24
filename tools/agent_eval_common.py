"""맞춤 에이전트 품질 평가 공통 (docs/agent-quality-eval-spec.md).

- 자료 위치: data/local은 git 제외라 worktree에 없다. --data 또는 환경변수 GWITTIM_DATA로 메인 폴더의 data/local을 준다
- 프로필 3종(§5.2), 외부 찾기 질의(§6.1), 무료 화면 칸(§5.3)
- 모든 결과는 <data>/agent_eval/ 아래에 쓴다
"""
from __future__ import annotations

import hashlib
import json
import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def data_dir(arg: str | None = None) -> Path:
    """data/local 위치. 인자 > 환경변수 GWITTIM_DATA > 저장소 안 data/local."""
    path = Path(arg or os.environ.get("GWITTIM_DATA") or ROOT / "data/local")
    if not (path / "notices.json").exists():
        raise SystemExit(f"notices.json이 없습니다: {path} (--data로 메인 폴더의 data/local을 주십시오)")
    return path


def eval_dir(data: Path) -> Path:
    out = data / "agent_eval"
    out.mkdir(parents=True, exist_ok=True)
    return out


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=1), encoding="utf-8")


def sha256_file(path: Path) -> str:
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


# ---------- 출처 묶음 (§5.1) ----------

GROUPS = {"kakao": "명지 알림톡", "mjc_board": "명지 홈페이지 게시판", "external": "교외(위비티·콘테스트코리아)",
          "sewu": "숭의"}
GROUP_QUOTA = {"kakao": 14, "mjc_board": 12, "external": 10, "sewu": 4}
HOLDOUT_QUOTA = {"kakao": 4, "mjc_board": 3, "external": 2, "sewu": 1}  # 보지 않는 10건
INFO_CATEGORIES = frozenset({"admin_notice", "academic", "event", "other"})  # 안내형
INFO_TOTAL = 8
PASSED_MAX = 4
# 명단형 공지(합격자·선발 결과·수상자). 사람 이름이 줄지어 나올 수 있어 표본에서 뺀다(§3)
ROSTER = re.compile(r"합격자|선발\s*결과|선정\s*결과|수상자|최종\s*명단|명단\s*발표|결과\s*발표|당선작\s*발표")


def group_of(key: str, notice: dict) -> str | None:
    src = notice.get("source_id") or key.split(":")[0]
    if src == "mjc_kakao":
        return "kakao"
    if src.startswith("mjc_www_"):
        return "mjc_board"
    if src in ("wevity_contest", "contestkorea_contest"):
        return "external"
    if src.startswith("sewu_"):
        return "sewu"
    return None


def school_of(group: str) -> str:
    return "sewu" if group == "sewu" else "mjc"  # 교외 공고는 명지로 둔다(§5.2)


# ---------- 프로필 (§5.2, 전부 합성) ----------

# P3 '최종 학년'은 학과 수업 연한 자료가 사전에 없어 2학년(전문대 최소 연한)으로 둔다. 휴학·칩 없음 경로를 보는 것이 목적
_PROFILE_BASE = {
    "P1": {"major": {"mjc": "mjc.computer_engineering", "sewu": "sewu.software_convergence"}, "grade": 2,
           "enrollment_status": "enrolled", "interest_ids": ["software", "ai_data"],
           "target_role_ids": ["software_developer"],
           "chips": {"experience": ["python", "team_project"], "period": "vacation", "regions": ["seoul"]}},
    "P2": {"major": {"mjc": "mjc.business_administration", "sewu": "sewu.business_management"}, "grade": 1,
           "enrollment_status": "enrolled", "interest_ids": ["business_marketing"], "target_role_ids": ["marketer"],
           "chips": {"experience": ["none_yet"], "period": "semester", "regions": ["gyeonggi_incheon"]}},
    "P3": {"major": {"mjc": "mjc.social_welfare", "sewu": "sewu.social_welfare"}, "grade": 2,
           "enrollment_status": "on_leave", "interest_ids": ["education_welfare"], "target_role_ids": ["social_worker"],
           "chips": {}},
}
PROFILE_NAMES = tuple(_PROFILE_BASE)


def profile(name: str, school: str) -> tuple[dict, dict]:
    """(기본 프로필, 요청 칩)."""
    base = _PROFILE_BASE[name]
    prof = {"university_id": school, "major_id": base["major"][school], "grade": base["grade"],
            "enrollment_status": base["enrollment_status"], "interest_ids": list(base["interest_ids"]),
            "target_role_ids": list(base["target_role_ids"])}
    return prof, json.loads(json.dumps(base["chips"]))


# ---------- 외부 찾기 질의 (§6.1) ----------

QUERY_CATEGORIES = ("contest", "extracurricular", "education_program", "internship")
QUERY_INTERESTS = ("software", "design", "business_marketing")
# 고치며 볼 12개 중 한 줄을 넣는 4개 (분류, 관심 분야) -> 한 줄. 학생이 실제로 적을 만한 짧은 말
QUERY_LINES = {
    ("contest", "software"): "앱 아이디어 공모전",
    ("extracurricular", "design"): "온라인으로 하는 서포터즈",
    ("education_program", "business_marketing"): "무료 마케팅 교육",
    ("internship", "software"): "방학 중 개발 인턴",
}
# 보지 않는 6개: 최종 측정 때만 쓴다
HOLDOUT_QUERIES = (
    ("contest", "ai_data", None),
    ("contest", "media_content", "영상 공모전"),
    ("extracurricular", "global_language", None),
    ("education_program", "ai_data", None),
    ("internship", "business_marketing", None),
    ("volunteer", "education_welfare", "교육 봉사"),
)


def query_set() -> list[dict]:
    """질의 18개. split: dev 12 / holdout 6. 프로필은 P1에서 관심 분야만 바꾼다."""
    rows = []
    for cat in QUERY_CATEGORIES:
        for interest in QUERY_INTERESTS:
            rows.append({"category": cat, "interest": interest, "query": QUERY_LINES.get((cat, interest)),
                         "split": "dev"})
    rows += [{"category": c, "interest": i, "query": q, "split": "holdout"} for c, i, q in HOLDOUT_QUERIES]
    for n, row in enumerate(rows, 1):
        row["id"] = f"Q{n:02}"
    return rows


def query_request(row: dict) -> tuple[dict, dict]:
    """(프로필, 요청 본문)."""
    prof, chips = profile("P1", "mjc")
    prof["interest_ids"] = [row["interest"]]
    body = {"request_id": f"eval-{row['id']}", "category": row["category"], "interests": [row["interest"]], **chips}
    body.pop("experience", None)  # 외부 찾기 요청에는 해 본 것 칩이 없다(external_search_request)
    if row.get("query"):
        body["query"] = row["query"]
    return prof, body


# ---------- 무료 화면 칸 (§5.3) ----------

# 앱 공고 상세 화면(apps/mobile/lib/ui/report_screen.dart `_body`)이 크레딧 없이 보이는 칸. 2026-11-24 화면 코드에서 확인
FREE_SCREEN_FIELDS = (
    "분류(category)", "제목(title)", "출처 이름·게시일(published)", "요약(summary, _SummaryBubble)",
    "체크리스트: 조건 근거 문장(eligibility.conditions[].evidence)",
    "체크리스트: 직접 확인·우대 사항 문장(eligibility.unresolved_conditions[].evidence)",
    "체크리스트: 누구나 지원 가능 근거(eligibility.unrestricted_evidence)",
    "추천 이유(관심 분야·전공 낱말, 2주 안 마감)",
    "일정: 신청 시작·신청 마감(시각 유무)·마감 메모(deadline_note)·활동 시작·활동 끝",
    "관련 공고 목록(제목)",
)


def free_screen_text(notice: dict) -> list[str]:
    """한 공고의 무료 화면에 보이는 글을 줄 목록으로. 정답지의 '무료 화면에 있음' 판단에 쓴다."""
    lines = [f"분류: {notice.get('category')}", f"제목: {notice.get('title')}"]
    if notice.get("summary"):
        lines.append(f"요약: {notice['summary']}")
    el = notice.get("eligibility") or {}
    for c in el.get("conditions") or []:
        lines.append(f"조건({c.get('field')}): {c.get('evidence')}")
    for u in el.get("unresolved_conditions") or []:
        lines.append(f"{u.get('note') or '직접 확인'}: {u.get('evidence')}")
    if el.get("unrestricted_evidence"):
        lines.append(f"누구나 지원 가능: {el['unrestricted_evidence']}")
    for key, label in (("application_start", "신청 시작"), ("application_deadline", "신청 마감")):
        d = notice.get(key) or {}
        if d.get("date"):
            lines.append(f"{label}: {d['date']}" + (f" {d['time']}" if d.get("time") else " (시각 없음)"))
    if notice.get("deadline_note"):
        lines.append(f"마감 메모: {notice['deadline_note']}")
    act = notice.get("activity_period") or {}
    for key, label in (("start", "활동 시작"), ("end", "활동 끝")):
        if (act.get(key) or {}).get("date"):
            lines.append(f"{label}: {act[key]['date']}")
    return lines


# ---------- 문자열 정리 (인용 대조용) ----------

_NOT_TEXT = re.compile(r"[^0-9A-Za-z가-힣]")


def norm(text: str) -> str:
    """공백·기호를 지운 소문자. 원문 문장이 본문에 있는지 볼 때 쓴다."""
    return _NOT_TEXT.sub("", text or "").lower()


def quote_in(quote: str, body: str) -> bool:
    q = norm(quote)
    return bool(q) and q in norm(body)
