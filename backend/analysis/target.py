"""지원 대상 낱말 읽기 (D-057, docs/student-target-extraction-spec.md).

공고 줄에서 '대학생', '재학 중', '일반인', '누구나' 같은 대상 낱말을 읽어, 프로필 학적(재학·휴학·졸업) 하나하나를
확인됨(confirmed) / 미확인(unconfirmed) / 해당 없음으로 나눈다. 원문이 뒷받침하는 범위까지만 확인됨으로 둔다.
이 모듈은 낱말 읽기만 한다. 조건·미해석 항목을 만드는 일은 rules.py가 한다.

- 새 낱말(대학생·재학 중·일반인 등)은 대상 문맥(ctx)에서만 읽는다. 옛 낱말(재학생·휴학생·졸업생)은 문맥과 관계없이 읽는다.
- 낱말 목록은 테스트(test_student_target.py)로 고정한다.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

ENROLLED, ON_LEAVE, GRADUATED = "enrolled", "on_leave", "graduated"
ORDER = (ENROLLED, ON_LEAVE, GRADUATED)
_TRIM = " ,;，；·"
_LEAD = r"(?:[○●◦•ㆍ·\-*※□■▶▷◎◆◇]\s*)*"

# 대상 항목 이름: '응모대상:', '참가 자격 /', '지원대상은'
TARGET_NAME = re.compile(r"(?:응모|참가|참여|모집|지원|신청)?\s*(?:대상|자격)(?:자)?(?:\s*요건)?")
TARGET_LABEL = re.compile(rf"^\s*{_LEAD}{TARGET_NAME.pattern}\s*(?:[:：]|\s/\s)\s*")
TARGET_BARE = re.compile(rf"^\s*{_LEAD}{TARGET_NAME.pattern}\s*(?:은|는)\s+")

# 대상 낱말. 순서가 곧 우선순위이고, 읽은 자리는 지워서 겹쳐 읽지 않는다. (종류, 정규식, 새 낱말인가)
_PATTERNS = [
    ("EL", r"재학\s*(?:또는|혹은|및|[·ㆍ,/])\s*휴학\s*(?:중(?:인)?)?(?:\s*(?:대학)?(?:학)?생)?", True),
    ("EL", r"재\s*[·ㆍ･•,/]\s*휴학생", False),
    ("GRADUATING", r"졸업\s*예정(?:자|생)?", False),
    ("G", r"졸업생|졸업자", False),
    ("L", r"휴학생", False),
    ("L", r"휴학\s*중(?:인)?", True),
    ("E", r"재학생", False),
    ("E", r"재학\s*중(?:인)?", True),
    ("UNIV", r"전문대학생|대학\(원\)생|대학교\s*학생|대학생", True),
    ("GRADSCHOOL", r"대학원생", True),
    # 학생이 아닌 대상: 함께 나열되면 다른 낱말로 확인되지 않은 학적은 미확인 (D-057). '주민등록'의 주민은 아니다
    ("GENERAL", r"일반인|직장인|외국인|기타|지역\s*주민|주민(?!\s*등록)|시민|도민", True),
    ("AGE", r"성인|청년|만?\s*\d+\s*세?\s*[~\-–]\s*\d+\s*세|만\s*\d+\s*세(?:\s*(?:이상|이하|미만))?|\d+\s*세\s*(?:이상|이하|미만)|해당자\s*[▶▷]", True),
    ("YOUNG", r"청소년|중\s*[·ㆍ,]\s*고등학생|중학생|고등학생|초등학생|유치원(?:생)?|어린이", True),
]
_COMPILED = [(name, re.compile(p), new) for name, p, new in _PATTERNS]
_STATUS_KINDS = {"EL", "E", "L", "G", "UNIV"}
# 나열 뒤에 범위를 넓히는 말: '대학생 등', '대학생 외', '및 그 밖에', '기타'
_BROADEN = re.compile(r"(?<![가-힣])(?:등|외)(?![가-힣])|그\s*밖|그\s*외")
_BROADEN_AFTER = re.compile(r"\s*(?:등|외)(?![가-힣])")  # 대상 낱말 바로 뒤
_BROADEN_OTHER = re.compile(r"그\s*밖|그\s*외")

# '휴학생 포함·제외', '졸업생 제외': 대상 문구에 붙은 괄호 안, 또는 '단,' 뒤에서만 학적을 좁힌다 (D-023의 예외)
_ADJ = re.compile(
    r"(?P<w>(?:휴학\s*생|휴학\s*중인?\s*(?:학생)?|졸업\s*생|졸업\s*자|재학\s*생)"
    r"(?:\s*(?:및|,|·|과|와)\s*(?:휴학\s*생|졸업\s*생|졸업\s*자|재등록\s*생|복학\s*생|재학\s*생))*)"
    r"\s*(?:도\s*)?(?:은\s*|는\s*)?(?P<k>포함|제외|불가|(?:신청|지원)\s*불가|할\s*수\s*없)"
)
_AFTER_DAN = re.compile(r"(?:단|다만)[,，]?\s*$")

# 대상 표지가 붙은 구절 (대상 문맥)
_W = r"(?:전문대학생|대학\(원\)생|대학교\s*학생|대학생|대학원생|재학생|휴학생|졸업생|일반인|성인|청년)"
_MARKERS = [
    re.compile(rf"{_W}\s*(?:대상자?(?:입니다)?|한정|한함)\s*(?:[.,，;；)）(（]|$)"),
    re.compile(rf"{_W}\s*(?:(?:이면|이라면|이며|이고)\s*)?누구나"),
    re.compile(rf"[가-힣]인\s+{_W}(?![가-힣])"),
    re.compile(rf"{_W}(?:으로|으로서)[^.]*?(?:인|한)\s*(?:자|사람|학생)"),
    re.compile(rf"{_W}만\s*(?:지원|신청|참여)"),
]

# '누구나' 앞에 이런 낱말이 있으면 신청 대상 전체가 아니라 한정된 대상이다
_QUAL = re.compile(
    r"대학(?:원)?생|대학원|전문대|학생|재학|휴학|졸업|청년|성인|청소년|국민|시민|주민|거주|국적|외국인|내국인"
    r"|\d+\s*세|연령|나이|본교|우리\s*대학|학과|전공|학년|재직|직장인|소속|출신|임직원|회원"
)
_NOT_QUAL = re.compile(r"(?:전|모든)\s*(?:국민|시민)|일반인|[가-힣·ㆍ,/\s]{0,20}(?:제한\s*없이?|무관)")
_RESIDUAL = re.compile(r"\d+\s*세|연령|나이|성인|청년|청소년|국민|시민|주민|거주|국적|외국인|내국인|재직|직장인|임직원|회원|소속|출신|전공|학과|학년")
_NO_LIMIT_ITEM = re.compile(r"(?:^|[,，;；])\s*(?:제한\s*없음|제한\s*없이|무관)\s*(?:[,，;；]|$)")
_OPEN, _CLOSE = "([（［", ")]）］"


def has_marker(text: str) -> bool:
    return any(p.search(text) for p in _MARKERS)


def value_of(line: str, strip_enum) -> str:
    """번호·기호와 대상 항목 이름('응모대상:', '지원대상은')을 뗀 문구."""
    t = strip_enum(line).strip()
    t = TARGET_LABEL.sub("", t, count=1)
    return TARGET_BARE.sub("", t, count=1)


def _clause_at(value: str, i: int) -> tuple[int, int]:
    spans, stack = [], []
    for k, ch in enumerate(value):
        if ch in _OPEN:
            stack.append(k)
        elif ch in _CLOSE and stack:
            spans.append((stack.pop() + 1, k))
    inner = [(a, b) for a, b in spans if a <= i < b]
    if inner:
        return min(inner, key=lambda s: s[1] - s[0])
    start, depth = 0, 0
    for k, ch in enumerate(value):
        if ch in _OPEN:
            depth += 1
        elif ch in _CLOSE:
            depth = max(0, depth - 1)
        elif depth == 0 and ch in ",，;；":
            if k < i:
                start = k + 1
            else:
                return start, k
    return start, len(value)


def scan_nugu(value: str) -> tuple[bool, list[tuple[int, int, str]]]:
    """'누구나'가 신청 대상 전체를 수식하는가 (D-057 3.4). (전체 수식 여부, 한정어가 붙은 구절들 (시작, 끝, 앞부분)).

    전체를 수식함: '누구나 지원 가능', 대상 칸의 독립 항목 '누구나'. 한정어가 붙음: '대학생이면 누구나', '18세 이상 … 누구나'.
    한정어가 붙은 것이 하나라도 있으면 전체 제한 없음으로 보지 않는다.
    """
    unqualified, qualified = False, []
    for m in re.finditer("누구나", value):
        a, b = _clause_at(value, m.start())
        prefix = value[a:m.start()]
        if _QUAL.search(_NOT_QUAL.sub(" ", prefix)):
            if (a, b) not in [(x, y) for x, y, _ in qualified]:
                qualified.append((a, b, prefix))
        else:
            unqualified = True
    return unqualified and not qualified, qualified


def _scan(text: str, new_ok: bool) -> list[tuple[str, int, int, bool]]:
    masked, out = text, []
    for name, rx, new in _COMPILED:
        if new and not new_ok:
            continue
        for m in rx.finditer(masked):
            if name == "GRADUATING" and re.match(r"\s*(?:도\s*)?포함", masked[m.end():]):
                # '재학생(졸업예정자 포함)': 넓히는 말이라 값을 바꾸지 않는다
                masked = masked[:m.start()] + " " * (m.end() - m.start()) + masked[m.end():]
                continue
            out.append((name, m.start(), m.end(), new))
            masked = masked[:m.start()] + " " * (m.end() - m.start()) + masked[m.end():]
    return out


@dataclass
class Target:
    conf: set[str] = field(default_factory=set)  # 확인됨
    unconf: set[str] = field(default_factory=set)  # 미확인
    found: bool = False  # 대상 낱말을 읽었는가(확인됨이 없어도). 새 낱말은 대상 문맥에서만
    whole: bool = False  # '누구나'가 신청 대상 전체를 수식
    new: bool = False  # 새 낱말·포함·제외를 썼는가(옛 모양 eq/in과 구분)
    univ: bool = False  # 대학생류 낱말이 있는가
    graduating: bool = False  # 졸업 예정 낱말
    age: bool = False  # 나이 낱말(한정 구절 밖)
    qualified: list[str] = field(default_factory=list)  # 학적으로 판정할 수 없는 한정어가 붙은 '누구나' 구절 (직접 확인)
    adj: bool = False  # 유효한 포함·제외를 썼는가
    masked: str = ""  # 유효한 포함·제외를 지운 문구(EXCLUDES 확인용)

    def add_confirmed(self, state: str) -> None:
        self.conf.add(state)
        self.unconf.discard(state)

    @property
    def values(self) -> list[str]:
        return [s for s in ORDER if s in self.conf]

    @property
    def unconfirmed(self) -> list[str]:
        return [s for s in ORDER if s in self.unconf]


def read(value: str, ctx: bool, school: str | None = None) -> Target:
    """대상 문구(번호·항목 이름을 뗀 것)에서 학적 낱말을 읽는다. ctx가 거짓이면 옛 낱말(재학생·휴학생·졸업생)만 읽는다."""
    tr = Target(masked=value)
    whole, nugu = scan_nugu(value)
    if ctx and not nugu and _NO_LIMIT_ITEM.search(value):
        whole = True  # 대상 칸의 독립 항목 '제한없음'
    spans = [(a, b) for a, b, _ in nugu]
    inside = lambda pos: any(a <= pos < b for a, b in spans)  # noqa: E731
    for a, b, prefix in nugu:
        toks = _scan(prefix, True)
        stripped = prefix
        for _, s, e, _ in toks:
            stripped = stripped[:s] + " " * (e - s) + stripped[e:]
        covered = any(n in _STATUS_KINDS for n, *_ in toks) or bool(re.search(r"본교|우리\s*대학", prefix))             or bool(school and school in prefix)
        if not covered or _RESIDUAL.search(stripped):
            tr.qualified.append(value[a:b].strip(_TRIM))
    toks = _scan(value, ctx)
    general = False
    excluded: set[str] = set()
    explicit_enrolled = False
    for name, s, e, new in toks:
        if inside(s) and name not in _STATUS_KINDS:
            continue  # 한정어가 붙은 구절 안의 나이·일반인 등은 그 구절이 직접 확인으로 맡는다
        if ctx:
            tr.found = True
        if new:
            tr.new = True
        if name == "EL":
            tr.conf |= {ENROLLED, ON_LEAVE}
        elif name in ("E", "L", "G"):
            tr.conf.add({"E": ENROLLED, "L": ON_LEAVE, "G": GRADUATED}[name])
            explicit_enrolled |= name == "E"
        elif name == "UNIV":
            tr.conf.add(ENROLLED)
            tr.unconf.add(ON_LEAVE)
            tr.univ = True
        elif name == "GENERAL":
            general = True
        elif name == "AGE":
            tr.age = True
            # '성인'·'청년'·'해당자 ▶ (…)'이 대상 하나로 나열되면 학생이 아닌 사람도 대상이다. 졸업생도 성인일 수 있으니 미충족이 아니라 미확인.
            # '재학생(만 20~69세)'처럼 숫자 나이가 대상을 꾸미는 경우는 대상을 넓히지 않는다
            general |= bool(re.match(r"성인|청년|해당자", value[s:e]))
        elif name == "GRADUATING":
            tr.graduating = True
    if ctx and tr.graduating:
        tr.new = True
    if tr.univ and explicit_enrolled:
        tr.unconf.discard(ON_LEAVE)  # '재학 중인 대학생'은 재학만 말한다
    if ctx:
        # 포함·제외는 대상 문구 괄호 안이나 '단,' 뒤에서만 학적을 좁힌다
        masked = value
        for m in _ADJ.finditer(value):
            before = value[:m.start()]
            in_paren = max(before.rfind("("), before.rfind("（")) > max(before.rfind(")"), before.rfind("）"))
            if not (in_paren or _AFTER_DAN.search(before[-8:])):
                continue
            states = set()
            if re.search(r"휴학", m["w"]):
                states.add(ON_LEAVE)
            if re.search(r"졸업", m["w"]):
                states.add(GRADUATED)
            if re.search(r"재학", m["w"]):
                states.add(ENROLLED)
            tr.adj = tr.new = True
            if m["k"] == "포함":
                tr.conf |= states
            else:
                tr.conf -= states
                excluded |= states
            masked = masked[:m.start()] + " " * (m.end() - m.start()) + masked[m.end():]
        tr.masked = masked
        # '등'·'외'는 대상 낱말 바로 뒤에 붙을 때만 대상 범위를 넓힌다('대학생 등'). '컴퓨터공학 등 관련 학과'의 '등'은 학과 나열이다
        broaden = any(_BROADEN_AFTER.match(value, e) for _, _, e, _ in toks) or bool(_BROADEN_OTHER.search(value))
        if general or (tr.conf and broaden):
            tr.unconf |= set(ORDER)
            tr.new = True
        if whole:
            tr.conf, tr.unconf, tr.found, tr.age, tr.univ, tr.graduating = set(), set(), False, False, False, False
    tr.whole = whole
    tr.unconf -= tr.conf | excluded
    return tr
