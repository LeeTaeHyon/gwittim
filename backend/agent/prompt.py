"""상세 분석 지시문 (docs/agent-privacy-spec.md §2·§11, D-039 지킬 선).

build_messages는 (system, user) 문자열 둘을 만든다.
- system: 출력 형식(4칸 JSON)과 지킬 선. 공고 본문 속 지시문은 따르지 않는다.
- user: 학생 정보와 공고 자료를 JSON으로. payload는 build_payload가 허용 칸만 담은 값이라
  이름·이메일·계정 ID는 들어갈 길이 없다. 여기서도 사용자 식별 칸은 받지 않는다.

내부 코드 노출 막기 (2026-11-22, 실호출에서 리포트에 not_met·enrollment_status·null이 그대로 나옴)
1. 보내기 전에 모든 코드를 한국어로 바꾼다. 칸 이름도 한국어다. 모델이 코드를 보지 못하면 옮겨 쓸 수 없다.
2. 지시문에 영어 코드·칸 이름을 쓰지 말라고 적는다.
3. 받은 리포트에서 알려진 코드가 나오면 scrub_codes가 한국어로 바꾼다(거절하지 않음).

근거 맞추기 (2026-11-23, 지침만으로는 역량에 모집 부문·강의 주제가 들어가고 마감 지난 공고에 '다음 모집' 할 일이 나옴)
- ground_report가 역량 줄을 공고의 '원문에서 확인할 조건' 원문과 대조해 근거 없는 줄을 빼고, '(우대)'는 원문 구분으로 다시 붙인다.
- 마감이 지났으면 할 일은 고정 문장, 미충족이면 지원서·근거 없는 일정 줄을 뺀다.
"""
from __future__ import annotations

import json
import re
from datetime import date
from functools import cache
from pathlib import Path

from backend.contracts import CONTRACTS_DIR

from .payload import EXPERIENCE_CHIPS, PERIOD_CHIPS, REGION_CHIPS

# 상세 분석 지침(하네스)은 backend/agent/harness/ 파일로 따로 둔다. 고칠 때는 그 폴더의 README.md 참고
HARNESS_DIR = Path(__file__).resolve().parent / "harness"
HARNESS_FILE = HARNESS_DIR / "detail_analysis.md"


def load_harness(path: Path | None = None) -> str:
    """지침 본문. 끝 공백은 뗀다. 시험 도구는 다른 파일(path)을 넣어 비교한다."""
    return Path(path or HARNESS_FILE).read_text(encoding="utf-8").strip()


# 지침을 고칠 때마다 올린다. 저장본 키와 로그에 들어가므로, 올리면 같은 입력도 새로 분석한다
HARNESS_VERSION = (HARNESS_DIR / "VERSION").read_text(encoding="utf-8").strip()
SYSTEM_PROMPT = load_harness()

VERDICT_KO = {"met": "충족", "not_met": "미충족", "needs_check": "확인 필요", "unknown": "확인 필요"}
FIELD_KO = {"university_id": "학교", "major_id": "학과", "grade": "학년", "enrollment_status": "학적 상태"}
ENROLLMENT_KO = {"enrolled": "재학", "on_leave": "휴학", "graduated": "졸업·졸업 예정"}
UNKNOWN_REASON_KO = {"condition_unresolved": "공고 조건을 자동으로 해석하지 못함", "profile_missing": "학생 정보 없음",
                     "value_unconfirmed": "공고가 그 학적(휴학·졸업 등)을 포함하는지 밝히지 않음"}
UNKNOWN = "미상"


@cache
def _names(dictionary: str) -> dict[str, str]:
    data = json.loads((CONTRACTS_DIR / "dictionaries" / f"{dictionary}.json").read_text(encoding="utf-8"))
    return {item["id"]: item["name_ko"] for item in data["items"] if "name_ko" in item}


def _name(dictionary: str, code) -> str:
    return _names(dictionary).get(code, UNKNOWN) if isinstance(code, str) else UNKNOWN


def _value_ko(field: str, value) -> str:
    """조건 값(코드) -> 한국어. 목록이면 쉼표로 잇는다."""
    if isinstance(value, list):
        return ", ".join(_value_ko(field, v) for v in value)
    if field == "university_id":
        return _name("universities", value)
    if field == "major_id":
        return _name("majors", value)
    if field == "grade":
        return f"{value}학년"
    if field == "enrollment_status":
        return ENROLLMENT_KO.get(value, UNKNOWN)
    return str(value)


def _date_ko(info) -> str:
    """date_info -> '2026-11-30' 또는 '2026-11-30 18:00'. 없으면 '미상'. 시간대를 지어 붙이지 않는다."""
    if not isinstance(info, dict) or not info.get("date"):
        return UNKNOWN
    return f"{info['date']} {info['time']}" if info.get("precision") == "minute" and info.get("time") else info["date"]


def _student(payload: dict) -> dict:
    """payload(코드) -> 한국어 칸. 값이 없는 칸은 빼서 미상으로 둔다."""
    s: dict = {}
    if "university_id" in payload:
        s["학교"] = _name("universities", payload["university_id"])
    if "major_id" in payload:
        s["학과"] = _name("majors", payload["major_id"])
    if "grade" in payload:
        s["학년"] = f"{payload['grade']}학년"
    if "enrollment_status" in payload:
        s["학적 상태"] = ENROLLMENT_KO[payload["enrollment_status"]]
    if payload.get("interest_ids"):
        s["관심 분야"] = [_name("interests", c) for c in payload["interest_ids"]]
    if payload.get("target_role_ids"):
        s["희망 직무"] = [_name("roles", c) for c in payload["target_role_ids"]]
    if payload.get("experience"):
        s["해 본 것"] = [EXPERIENCE_CHIPS[c] for c in payload["experience"]]
    if payload.get("period"):
        s["가능한 시기"] = PERIOD_CHIPS[payload["period"]]
    if payload.get("regions"):
        s["갈 수 있는 지역"] = [REGION_CHIPS[c] for c in payload["regions"]]
    return s


def deadline_passed(notice: dict, today: date) -> bool:
    """마감 날짜가 오늘(한국 날짜)보다 앞이면 True. 마감 미상이면 False."""
    day = (notice.get("application_deadline") or {}).get("date")
    return bool(day) and day < today.isoformat()


def _notes(el: dict) -> list[str]:
    notes = []
    if not el.get("extraction_complete"):
        notes.append("공고의 지원 조건을 모두 찾지 못했을 수 있어 원문 확인이 필요함")
    if el.get("explicitly_unrestricted"):
        notes.append("공고에 누구나 지원할 수 있다고 적혀 있음")
    return notes


def build_messages(
    notice: dict, payload: dict, eligibility: tuple[str, list[dict]], today: date,
) -> tuple[str, str]:
    """eligibility는 backend.recommendation.evaluate의 결과 (상태, 조건별 결과). today는 한국 날짜."""
    status, results = eligibility
    el = notice["eligibility"]
    conditions = {c["field"]: c for c in el.get("conditions", [])}
    by_field = []
    for r in results:
        item = {
            "항목": FIELD_KO.get(r["field"], "기타 조건"),
            "결과": VERDICT_KO.get(r["status"], "확인 필요"),
            "근거": r.get("evidence") or UNKNOWN,
        }
        cond = conditions.get(r["field"])
        if cond is not None:
            item["공고 조건"] = _value_ko(r["field"], cond.get("value"))
        if r.get("unknown_reason"):
            item["확인 필요 이유"] = UNKNOWN_REASON_KO.get(r["unknown_reason"], "확인 필요")
        by_field.append(item)
    material = {
        "오늘": today.isoformat(),
        "학생": _student(payload),
        "공고": {
            "제목": notice["title"],
            "분류": _name("categories", notice.get("category")),
            "요약": notice["summary"],
            "마감": _date_ko(notice.get("application_deadline")),
            "지원 자격 판정": {
                "결과": VERDICT_KO.get(status, "확인 필요"),
                "조건별 결과": by_field,
                # 자동 비교하지 못한 조건 원문. 구분이 '우대 사항'이면 자격이 아니라 갖추면 유리한 조건
                "원문에서 확인할 조건": [
                    {"원문": u.get("evidence") or UNKNOWN, "구분": u.get("note") or "자격 조건"}
                    for u in el.get("unresolved_conditions", [])
                    if u.get("note") != NO_LIMIT_NOTE  # 항목 제한 없음은 확인할 조건이 아니다
                ],
                # 예/아니요 칸은 모델이 '조건을 모두 찾았는지 여부는 아니요' 식으로 옮겨 써서 문장으로 준다
                "참고": _notes(el),
            },
        },
    }
    if deadline_passed(notice, today):
        material["공고"]["마감 지남"] = "마감이 오늘보다 앞이라 이미 지났음"
    activity = notice.get("activity_period") or {}
    if activity.get("start") or activity.get("end"):
        # 활동 기간을 못 뽑았을 때 '미상'으로 보내면 요약에 적힌 기간까지 모른다고 판단해서, 있을 때만 넣는다
        material["공고"]["활동 기간"] = f"{_date_ko(activity.get('start'))} ~ {_date_ko(activity.get('end'))}"
    return SYSTEM_PROMPT, json.dumps(material, ensure_ascii=False, indent=1)


# ---------- 3. 받은 리포트의 코드 바꾸기 ----------

@cache
def _code_table() -> dict[str, str]:
    """리포트에 새어 나오면 바꿀 코드 -> 한국어. 밑줄·점이 든 코드와 아래 몇 개만 넣는다.

    밑줄 없는 영어 낱말(any, contest, python 등)은 공고 속 영어와 겹칠 수 있어 넣지 않는다.
    """
    table: dict[str, str] = {}
    for dictionary in ("universities", "majors", "interests", "roles", "categories"):
        for code, name in _names(dictionary).items():
            if "_" in code or "." in code:
                table[code] = name
    for chips in (EXPERIENCE_CHIPS, PERIOD_CHIPS, REGION_CHIPS):
        table.update({c: n for c, n in chips.items() if "_" in c})
    table.update({k: v for k, v in VERDICT_KO.items() if k != "unknown"})
    table.update(FIELD_KO)
    table.update({"interest_ids": "관심 분야", "target_role_ids": "희망 직무", "application_deadline": "마감"})
    table.update(ENROLLMENT_KO)
    table.update(UNKNOWN_REASON_KO)
    table.update({"unresolved_conditions": "원문에서 확인할 조건", "extraction_complete": "조건 확인",
                  "explicitly_unrestricted": "누구나 지원 가능", "null": UNKNOWN, "None": UNKNOWN})
    return table


_URL = re.compile(r"(https?://\S+|www\.\S+)")


@cache
def _code_patterns() -> tuple[re.Pattern, re.Pattern, re.Pattern]:
    codes = "|".join(re.escape(c) for c in sorted(_code_table(), key=len, reverse=True))
    edge_l, edge_r = r"(?<![A-Za-z0-9_./-])", r"(?![A-Za-z0-9_/-])"  # URL·영어 낱말 안쪽은 건드리지 않음
    code = rf"`?{edge_l}({codes}){edge_r}`?"
    gloss_after = re.compile(rf"{code}\s*\(([^()]{{1,20}})\)")  # not_met(미충족) -> 미충족
    gloss_before = re.compile(rf"\s*\(\s*{code}\s*\)")  # 미충족(not_met) -> 미충족
    bare = re.compile(code)
    return gloss_after, gloss_before, bare


def scrub_codes(report: dict) -> tuple[dict, int]:
    """리포트 각 칸에서 알려진 내부 코드를 한국어로 바꾼다. (바꾼 리포트, 바꾼 횟수)."""
    gloss_after, gloss_before, bare = _code_patterns()
    table = _code_table()
    total = 0
    out = {}
    for k, text in report.items():
        if not isinstance(text, str):
            out[k] = text
            continue
        parts = _URL.split(text)  # 홀수 번째 조각은 주소. 주소 안은 건드리지 않는다
        for i in range(0, len(parts), 2):
            seg, n1 = gloss_after.subn(lambda m: m.group(2), parts[i])
            seg, n2 = gloss_before.subn("", seg)
            seg, n3 = bare.subn(lambda m: table[m.group(1)], seg)
            parts[i] = seg
            total += n1 + n2 + n3
        out[k] = "".join(parts)
    return out, total


# ---------- 긴 문단 나누기 ----------

_SENTENCE_END = re.compile(r"(?<=[다음함임됨])\.\s+(?=\S)")
BR = chr(10)
LONG_LINE = 90  # 이보다 긴 줄은 문장 끝에서 나눈다


def split_long_lines(report: dict) -> tuple[dict, int]:
    """지시문을 어기고 한 문단으로 온 칸을 문장 끝(…다. / …음. / …함.)에서 줄로 나눈다. (리포트, 나눈 줄 수).

    화면은 줄 하나를 항목 하나로 보이므로, 긴 문단은 읽기 어렵다. 내용은 바꾸지 않는다.
    """
    out, total = {}, 0
    for k, text in report.items():
        if not isinstance(text, str):
            out[k] = text
            continue
        lines = []
        for line in text.split(BR):
            if len(line) > LONG_LINE:
                parts = [p.strip() for p in _SENTENCE_END.split(line) if p.strip()]
                parts = [p if p.endswith(".") else p + "." for p in parts[:-1]] + parts[-1:]
                total += len(parts) - 1
                lines.extend(parts)
            else:
                lines.append(line)
        out[k] = BR.join(lines)
    return out, total


# ---------- 근거 맞추기 (역량·할 일) ----------

SKILLS_UNKNOWN = "제공된 공고 정보에서 요구 역량을 확인하기 어렵습니다."
FIT_UNKNOWN = "확인 필요: 공고 자료만으로는 해 본 것과 이어지는 점을 확인하기 어렵습니다."
TODO_NONE = "이번 모집은 지원 전에 할 일이 없습니다."
PREFERRED_NOTE = "우대 사항"  # unresolved_condition.note (backend.analysis.rules.PREFERRED_NOTE와 같은 값)
NO_LIMIT_NOTE = "항목 제한 없음"  # 한 항목에만 제한이 없다는 문구. 확인할 조건이 아니다 (rules.NO_LIMIT_NOTE와 같은 값, D-056)
SKILL_MATCH = 0.5  # 역량 줄의 두 글자 묶음 중 이 비율 이상이 한 원문에 있어야 근거로 본다
_PREF_MARK = re.compile(r"\s*[(（]\s*우대\s*[)）]\s*$")
_NOT_TEXT = re.compile(r"[^0-9A-Za-z가-힣]")
# 미충족 공고 할 일에서 뺄 줄: 지원서 준비, 공고 자료에 없는 다음 일정·경로
_NOT_MET_TODO = re.compile(
    r"지원서|자기\s*소개서|이력서|포트폴리오|정리해\s*둡|다음\s*모집|추가\s*모집|다음\s*학기|다음\s*공고|학과\s*공지"
)


def _grams(text: str) -> set[str]:
    t = _NOT_TEXT.sub("", text).lower()
    return {t[i:i + 2] for i in range(len(t) - 1)} or ({t} if t else set())


def _best_evidence(line: str, evidence: list[dict], preferred: bool = False) -> dict | None:
    """역량 줄과 두 글자 묶음이 가장 많이 겹치는 원문 조건. SKILL_MATCH 미만이면 None.

    같은 점수면 줄에 모델이 붙인 '(우대)' 표시(preferred)와 같은 구분의 조건을 고른다. 같은 문구가 필수·우대에 각각 있을 때 섞이지 않게 한다.
    """
    grams = _grams(line)
    if not grams:
        return None
    best, score = None, 0.0
    for u in evidence:
        if u.get("note") == NO_LIMIT_NOTE:
            continue
        s = len(grams & _grams(u.get("evidence") or "")) / len(grams)
        same_kind = (u.get("note") == PREFERRED_NOTE) == preferred
        best_same_kind = best is not None and (best.get("note") == PREFERRED_NOTE) == preferred
        if s > score or (s == score and best is not None and same_kind and not best_same_kind):
            best, score = u, s
    return best if score >= SKILL_MATCH else None


_QUOTE = re.compile(r"['‘’]([^'‘’]+)['‘’]")


def ground_fit_links(report: dict, notice: dict, payload: dict) -> tuple[dict, int]:
    """'fit' 줄 중 작은따옴표 인용('…')이 있는 줄을 근거로 걸러 낸다. (리포트, 뺀 줄 수). 경험·우대 조건 잇기(report-reminder-spec §3.2).

    남기는 조건: 인용이 이 공고의 '우대 사항' 원문에 있고(공백·기호를 뺀 뒤 문자열로),
    줄에 학생이 이번에 고른 '해 본 것' 이름이 있어야 한다. 아니면 그 줄을 뺀다. 인용이 없는 줄은 건드리지 않는다.
    줄이 모두 빠지면 칸이 비므로 원문 확인이 필요하다는 고정 문장을 둔다.
    """
    text = report.get("fit")
    if not isinstance(text, str):
        return report, 0
    unresolved = (notice.get("eligibility") or {}).get("unresolved_conditions") or []
    preferred = [_NOT_TEXT.sub("", u.get("evidence") or "") for u in unresolved if u.get("note") == PREFERRED_NOTE]
    chips = [_NOT_TEXT.sub("", EXPERIENCE_CHIPS[c]) for c in (payload or {}).get("experience") or [] if c in EXPERIENCE_CHIPS]
    kept, dropped = [], 0
    for line in text.split(BR):
        quotes = _QUOTE.findall(line) if "우대" in line else []  # 우대 연결 줄만 검사. 다른 인용은 건드리지 않음
        if quotes:
            flat = _NOT_TEXT.sub("", line)
            cited = [_NOT_TEXT.sub("", q) for q in quotes]
            grounded = all(q and any(q in ev for ev in preferred) for q in cited)
            if not (grounded and any(chip and chip in flat for chip in chips)):
                dropped += 1
                continue
        kept.append(line)
    if not dropped:
        return report, 0
    out = dict(report)
    out["fit"] = BR.join(kept) if any(k.strip() for k in kept) else FIT_UNKNOWN
    return out, dropped


# '맞음:'인데 단정하지 않고 끝나는 줄. 예: "~이어지는지 확인할 수 있습니다", "~일 수 있습니다"
_FIT_HEDGE = re.compile(r"지\s*(?:확인|살펴|알아)|일\s*수\s*있|확인할\s*수\s*있|알\s*수\s*없|확인이\s*필요")
FIT_MET, FIT_CHECK = "맞음:", "확인 필요:"


def relabel_hedged_fit(report: dict) -> tuple[dict, int]:
    """'fit'에서 '맞음:'으로 시작하지만 단정하지 않는 줄을 '확인 필요:'로 바꾼다. (리포트, 바꾼 줄 수)."""
    text = report.get("fit")
    if not isinstance(text, str):
        return report, 0
    lines, n = [], 0
    for line in text.split(BR):
        s = line.lstrip()
        if s.startswith(FIT_MET) and _FIT_HEDGE.search(s):
            line, n = FIT_CHECK + s[len(FIT_MET):], n + 1
        lines.append(line)
    if not n:
        return report, 0
    return {**report, "fit": BR.join(lines)}, n


def ground_report(report: dict, notice: dict, status: str, today: date, payload: dict | None = None) -> tuple[dict, dict]:
    """받은 리포트의 역량·할 일을 공고 자료에 맞춘다. (리포트, 바꾼 내용 {'skills_dropped': n, 'todo': 사유, 'fit_link_dropped': n, 'fit_hedge_relabeled': n}).

    - 단정 확인: '맞음:'인데 '~인지 확인할 수 있습니다'처럼 끝나는 줄은 '확인 필요:'로 바꾼다(relabel_hedged_fit).

    - 경험 잇기: payload(학생이 고른 칩)를 주면 'fit'의 따옴표 인용 줄을 ground_fit_links로 거른다.

    - 역량: 공고의 '원문에서 확인할 조건' 원문에 근거가 있는 줄만 남긴다. '(우대)'는 모델 표시가 아니라 원문 구분으로 붙인다.
      남는 줄이 없으면 '확인하기 어렵습니다' 문장.
    - 할 일: 마감이 지났으면 고정 문장. 미충족이면 지원서·근거 없는 일정 줄을 빼고, 남는 줄이 없으면 고정 문장.
    """
    out, changes = dict(report), {}
    out, hedged = relabel_hedged_fit(out)
    if hedged:
        changes["fit_hedge_relabeled"] = hedged
    if payload is not None:
        out, fit_dropped = ground_fit_links(out, notice, payload)
        if fit_dropped:
            changes["fit_link_dropped"] = fit_dropped
    evidence = (notice.get("eligibility") or {}).get("unresolved_conditions") or []

    skills = [ln.strip() for ln in str(report.get("skills", "")).split(BR) if ln.strip()]
    if not any("요구 역량을 확인하기 어렵습니다" in ln for ln in skills):
        kept = []
        for ln in skills:
            u = _best_evidence(_PREF_MARK.sub("", ln), evidence, bool(_PREF_MARK.search(ln)))
            if u is None:
                continue
            name = _PREF_MARK.sub("", ln)
            kept.append(f"{name} (우대)" if u.get("note") == PREFERRED_NOTE else name)
        if len(kept) != len(skills):
            changes["skills_dropped"] = len(skills) - len(kept)
        out["skills"] = BR.join(kept) if kept else SKILLS_UNKNOWN

    if deadline_passed(notice, today):
        if out.get("todo") != TODO_NONE:
            changes["todo"] = "deadline_passed"
        out["todo"] = TODO_NONE
    elif status == "not_met":
        todo = [ln for ln in str(report.get("todo", "")).split(BR) if ln.strip()]
        kept = [ln for ln in todo if not _NOT_MET_TODO.search(ln)]
        if len(kept) != len(todo):
            changes["todo"] = "not_met_filtered"
        out["todo"] = BR.join(kept) if kept else TODO_NONE
    return out, changes
