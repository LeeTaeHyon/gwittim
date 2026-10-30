"""PC 카톡 '대화 내보내기' txt 파싱: 메시지 나누기 · 알림 종류 판정 · 개인정보 가림 · 중복 묶기 (D-019).

학습 데이터(localModel/kakao_preprocess.py)와 수집(adapter.py)이 같은 코드를 쓴다.
같은 전처리를 거쳐야 모델이 배운 입력과 서비스에서 받는 입력이 같아진다.

kind
  broadcast        학생 전체·다수 대상 공지 (게시·추천 대상은 이것뿐)
  personal_course  수강 과목 알림(○○ 801반, 미수강·미제출·출석률)
  personal_account 이름·학번이 들어간 개인 알림
  participant      신청·참여한 학생에게만 보낸 운영 안내(승인, 참석 확인, 만족도 조사, 수료 현황)
  noise            채널 자동응답·빈 템플릿
"""
from __future__ import annotations

import collections
import hashlib
import os
import re
from collections.abc import Iterable
from datetime import date

DATE_RE = re.compile(r"^-{5,} (\d{4})년 (\d{1,2})월 (\d{1,2})일 \S+ -{5,}$")
MSG_RE = re.compile(r"^\[(.+?)\] \[(오전|오후) (\d{1,2}):(\d{2})\] ?(.*)$")
URL_RE = re.compile(r"https?://\S+")

BOILERPLATE = (
    "관리자가 없을때 대신 답변하는 채널 AI에요.",
    "채널 관리자가 없을 때 제가 대신 답변해 드려요.",
    "카나나 상담매니저가 문의에 응대하는 채널입니다. 답변 내용은 해당 채널에서 관리합니다.",
)
BOT_GREETINGS = ("상담매니저예요", "채널 AI 매니저예요")
COURSE_RE = re.compile(r"[가-힣A-Za-z0-9·Ⅰ-Ⅹ\-]+ ?\d{3}반")
COURSE_WORDS = ("아직 수강하지 않았습니다", "미제출", "미응시", "출석률", "수강기한", "온에어")
# 이름이 들어간 메시지 중 개인 결과·처리 내역만 개인 알림으로 본다 (나머지는 이름만 끼운 단체 발송)
ACCOUNT_RE = re.compile(r"결과\s*:|완료되었")
STUDENT_ID_RE = re.compile(r"(?<!\d)20\d{8}(?!\d)")
# '<학번>_홍길동' 같은 예시가 아니라 수신자를 가리키는 학번
RECIPIENT_ID_RE = re.compile(r"(?<!\d)20\d{8}\s*학생")
TEMPLATE_RE = re.compile(r"#\{[^}]*\}")
# 이미 신청·참여한 학생에게만 보낸 운영 안내. 다른 학생에게 추천할 수 없다
PARTICIPANT_RE = re.compile(
    r"(신청|참여)(해|하여) ?주(셔서|신) 감사"
    r"|참여하고 계신|튜터/튜티|튜터분들"
    r"|(참여|신청) ?학생(들)? ?(전체를 ?)?(대상|여러분|들에게|들은)"
    r"|(진행된|진행되었던|완료됨에 따라|완료에 따라|종료 안내).{0,40}만족도"
    r"|대상 ?: ?[^.\n]{0,20}참여자"
    r"|수료 ?현황|학습시간 현황|제출 ?현황|신청 및 승인이|신청 확정|수료 ?조건 필수|학습컨설턴트 ?:"
    r"|참여가 어려운|참석이 어려우신 경우"
)
# 참여자 표현이 있어도 아직 신청을 받는 공지는 공통 공지로 둔다
RECRUIT_RE = re.compile(r"모집|신청 ?안내|신청 ?기간|신청 ?방법|신청 ?마감|빠른 ?신청|까지 신청")
# 내용 판단에서 뺄 인사·머리말·문의 줄
FILLER_LINE_RE = re.compile(r"^(\[[^\]]*\]|안녕하세요.*|문의.*)$")
MOBILE_RE = re.compile(r"01[016789]-?\d{3,4}-?\d{4}")
PROF_RE = (
    re.compile(r"((?:담당|책임)교수\s*:?\s*)[가-힣]{3}"),
    re.compile(r"[가-힣]{3}(?=\s?교수(?:입니다|님|\]))"),
)
HONORIFIC_RE = re.compile(r"([가-힣]{2,4})님")
NOT_NAMES = {"학생", "교수", "선생", "담당자", "여러분", "고객", "회원", "사용자", "참여자", "신청자", "재학생", "학우"}

# 거의 같은 메시지로 볼 글자 3-gram 자카드 유사도, 같은 공지로 묶을 최대 간격(일)
NEAR_DUP = 0.8
DUP_WINDOW_DAYS = 45


def room_of(path: str) -> str:
    """'KakaoTalk_20261029_1935_53_981_명지전문대학 공지사항.txt' → '명지전문대학 공지사항'"""
    return os.path.basename(path)[:-4].split("_", 5)[-1]


def parse_export(path: str) -> list[dict]:
    room = room_of(path)
    with open(path, encoding="utf-8-sig") as f:
        lines = f.read().splitlines()[2:]  # 첫 두 줄은 방 이름·저장 날짜
    msgs, day, cur = [], None, None
    for line in lines:
        d = DATE_RE.match(line)
        if d:
            day = tuple(int(x) for x in d.groups())
            cur = None
            continue
        m = MSG_RE.match(line)
        if m and day:
            sender, ampm, h, mi, first = m.groups()
            h = int(h) % 12 + (12 if ampm == "오후" else 0)
            cur = {
                "room": room,
                "sender": sender,
                "sent_at": f"{day[0]:04d}-{day[1]:02d}-{day[2]:02d}T{h:02d}:{mi}:00+09:00",
                "lines": [first],
            }
            msgs.append(cur)
        elif cur is not None:
            cur["lines"].append(line)
    return msgs


def clean_body(m: dict) -> str:
    out = [l.rstrip() for l in m["lines"] if l.strip() not in BOILERPLATE]
    text = TEMPLATE_RE.sub("", "\n".join(out)).strip()
    return re.sub(r"\n{3,}", "\n\n", text)


# 제목으로 쓰지 않는 인사·부서 소개·발송 안내 ("명지전문대학 원격교육지원센터입니다.", "즐거운 개강입니다!")
GREETING_RE = re.compile(r"^\W*안녕하세요\W*(?:<?이름>?\s*님\W*)?")  # 가린 수신자 이름 호칭도 함께
INTRO_RE = re.compile(
    r"^\W*(?:명지전문대학\s*)?[가-힣A-Za-z·\s]{0,20}(?:센터|팀|실|과|처|원|단|관|본부|위원회|대학)\s*"
    r"(?:입니다|에서\s*안내(?:해)?\s*드립니다)\W*"
)
SKIP_TITLE_RE = re.compile(r"^\W*저는\s.*봇\W*입니다|발송되는\s*메[세시]지|^\W*즐거운\s*\S+\s*입니다\W*$|^\W*<?이름>?\s*님\W*$")


def title_of(text: str, room: str) -> str:
    short_room = room.replace("명지전문대학", "").strip()
    for l in text.splitlines():
        s = l.strip()
        if not s or re.fullmatch(r"\[[^\]]*\]", s) or s in (room, short_room) or SKIP_TITLE_RE.search(s):
            continue
        s = INTRO_RE.sub("", GREETING_RE.sub("", s)).strip()
        if s:
            return s[:80]
    return ""


def detect_names(texts: Iterable[str]) -> set[str]:
    # 여러 메시지에 반복해서 나오는 '○○○님'을 수신자 이름으로 본다
    cnt = collections.Counter()
    for t in texts:
        cnt.update(set(HONORIFIC_RE.findall(t)))
    return {n for n, c in cnt.items() if c >= 2 and n not in NOT_NAMES and len(n) == 3}


def mask(text: str, names: Iterable[str]) -> str:
    text = STUDENT_ID_RE.sub("<학번>", text)
    text = MOBILE_RE.sub("<휴대폰>", text)
    text = PROF_RE[0].sub(r"\1<교수>", text)
    text = PROF_RE[1].sub("<교수>", text)
    for n in names:
        text = text.replace(n, "<이름>")
    return text


def classify(text: str, names: Iterable[str]) -> str:
    body = re.sub(r"\s+", " ", text)
    content = "".join(l for l in text.splitlines() if not FILLER_LINE_RE.match(l.strip()))
    if len(content.strip()) < 15 or any(g in body for g in BOT_GREETINGS):
        return "noise"
    if RECIPIENT_ID_RE.search(body) or (any(n in body for n in names) and ACCOUNT_RE.search(body)):
        return "personal_account"
    if COURSE_RE.search(body) and (any(w in body for w in COURSE_WORDS) or "공지사항을 다음과 같이" in body or "안내입니다" in body):
        return "personal_course"
    if any(w in body for w in COURSE_WORDS):
        return "personal_course"
    if PARTICIPANT_RE.search(body) and not RECRUIT_RE.search(body):
        return "participant"
    return "broadcast"


def shingles(text: str) -> set[str]:
    s = re.sub(r"\s+", "", URL_RE.sub("", text))
    return {s[i : i + 3] for i in range(max(len(s) - 2, 1))}


def jaccard(a: set, b: set) -> float:
    return len(a & b) / len(a | b) if a and b else 0.0


def read_exports(paths: Iterable[str]) -> tuple[list[dict], dict[str, list[dict]]]:
    """내보내기 파일들 → (전체 메시지, 중복 묶음 {묶음 ID: 메시지 목록}).

    메시지에 id·kind·masked·title·urls·hash·dup_group을 채운다. 묶음 ID(g0000)는 파일·메시지 순서대로 붙는
    학습용 번호라 내보내기 파일이 바뀌면 달라질 수 있다. 수집에서는 stable_id()를 쓴다.
    """
    msgs = [m for p in sorted(paths) for m in parse_export(p)]
    for m in msgs:
        m["text"] = clean_body(m)
    names = detect_names(m["text"] for m in msgs)

    for i, m in enumerate(msgs):
        m["id"] = f"k{i:04d}"
        m["kind"] = classify(m["text"], names)
        m["masked"] = mask(m["text"], names)
        m["title"] = title_of(m["masked"], m["room"])
        m["urls"] = URL_RE.findall(m["masked"])
        m["hash"] = hashlib.sha1(re.sub(r"\s+", "", m["masked"]).encode()).hexdigest()[:12]

    # 중복 묶기: 같은 방, 직전 발송에서 DUP_WINDOW_DAYS 안, 완전 일치 또는 거의 같은 본문
    groups: dict[str, list[dict]] = {}
    reps: list[dict] = []
    for m in msgs:
        sh = shingles(m["masked"])
        day = date.fromisoformat(m["sent_at"][:10])
        hit = None
        for rep in reps:
            if rep["room"] != m["room"] or (day - rep["last"]).days > DUP_WINDOW_DAYS:
                continue
            if rep["hash"] == m["hash"] or jaccard(rep["sh"], sh) >= NEAR_DUP:
                hit = rep
                break
        if hit is None:
            hit = {"room": m["room"], "hash": m["hash"], "sh": sh, "gid": f"g{len(reps):04d}"}
            reps.append(hit)
        hit["last"] = day
        m["dup_group"] = hit["gid"]
        groups.setdefault(hit["gid"], []).append(m)
    return msgs, groups


def stable_id(first: dict) -> str:
    """묶음의 첫 메시지(방·발송 시각·본문)로 만든 ID. 나중에 내보낸 파일에 메시지가 늘어도 바뀌지 않는다."""
    key = f"{first['room']}|{first['sent_at']}|{first['hash']}"
    return hashlib.sha1(key.encode("utf-8")).hexdigest()[:16]
