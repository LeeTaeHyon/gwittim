"""규칙 기반 분석기: 결정적 파싱만으로 RawNotice에서 구조화 정보를 뽑는다.

LLM 분석기(W8 이후)는 같은 Analyzer 인터페이스로 교체·보강한다. 규칙 분석기는 스스로 추출이 완전하다고
판단할 근거가 약하므로, 첨부·미해석 조건·조건 미발견이 있으면 extraction_complete=false로 둔다.
"""
from __future__ import annotations

import json
import re
from functools import cache
from pathlib import Path
from typing import Protocol

from backend.contracts import CONTRACTS_DIR
from backend.sources import SourceConfig

from .dates import date_info, parse_line

ANALYSIS_VERSION = "rule-0.7"  # 0.7: LLM 미해석 조건은 신청자 본인 조건만(D-023). 0.6: 미해석 조건 정리·우대 사항 표시(D-015). 0.5: 근로·근무 기간은 마감 아님. 0.4: 이미지 대체텍스트, 두 자리 연도(D-014). 0.3: 장학·채용·근로 게시판(D-013). 0.2: 부서명 오탐 제거, 직무·학과 키워드, admin_notice


class Analyzer(Protocol):
    version: str

    def analyze(self, raw: dict, source: SourceConfig) -> dict:
        """Notice 분석 필드(category, tags, 날짜, eligibility, summary)를 돌려준다."""
        ...


# ---------- 사전 ----------

@cache
def _dictionary(name: str) -> list[dict]:
    path: Path = CONTRACTS_DIR / "dictionaries" / f"{name}.json"
    return json.loads(path.read_text(encoding="utf-8"))["items"]


# ---------- 키워드 표 (제목 우선, 첫 일치) ----------

# 학생 대상 기회가 아닌 공지(교직원 채용, 시설·행정 안내). 제목으로만 판단하고, 추천에서는 빼되 게시는 한다.
ADMIN_TITLE = re.compile(
    r"(?:교수|교원|강사|직원|조교)\s*(?:초빙|공개\s*채용|채용)|교직원|정기\s*점검|안전\s*진단|주차장|청소\s*작업|보건실"
    r"|국민\s*행동\s*요령|라이선스|입찰|휴무|정전|단수|시스템\s*점검"
)
# 채용공지 게시판의 외부 기관 '직원 채용'은 학생이 지원할 채용이다. 이 게시판에서는 학교의 교원·교직원 채용만 행정 공지로 본다.
JOB_BOARD_ADMIN_TITLE = re.compile(r"(?:교수|교원|강사|조교)\s*(?:초빙|공개\s*채용|채용)|교직원|명지전문대학?\s*(?:신규\s*)?직원")
JOB_BOARDS = {"mjc_www_job"}

# 장학·학사 공지 본문은 여러 장학 종류와 서류를 나열해서 키워드가 엉뚱하게 걸린다. 꼬리표는 제목에서만 찾는다.
TITLE_ONLY_TAG_CATEGORIES = {"scholarship", "academic"}

# 꼬리표 키워드 판정 전에 지우는 부서·센터 이름 (예: '취·창업팀'이 창업 공고로, 'AI·IR센터'가 AI 공고로 잡히던 문제)
TAG_NOISE = re.compile(
    r"(?:진로)?\s*취\s*[·ㆍ・.]?\s*창업\s*(?:팀|지원센터|센터)|AI\s*[·ㆍ・]\s*IR\s*(?:센터|팀)|글로벌\s*교육\s*(?:센터|팀)"
)

CATEGORY_RULES = [
    ("contest", r"공모전|경진대회|해커톤|대회"),
    ("scholarship", r"장학"),
    ("internship", r"인턴|현장실습"),
    ("job", r"채용|구인|근로\s*학생"),
    ("volunteer", r"봉사"),
    ("global", r"해외|연수|교환학생|유학(?!생)"),
    ("startup", r"창업"),
    ("extracurricular", r"비교과|마일리지|역량"),
    ("education_program", r"교육생|특강|강좌|과정|교육"),
    ("event", r"행사|박람회|축제|설명회|포럼|바자회"),
    ("academic", r"수강\s*(?:신청|정정|철회)|학사|성적|졸업|등록금|강의평가|시험"),  # '콘텐츠 수강 안내'는 학사 안내가 아님
]

# 공공기관 채용(채용공지의 공단·공사 공고). '공사'는 건설 공사와 겹쳐서 기관 이름 꼴만 본다.
PUBLIC_ORG = (
    r"공무원|공공기관|공기업|공단|(?:도시|에너지|공항|관광|주택|도로|철도|가스|전력|교육방송)\s*공사|관리원|진흥원|기술원"
)

INTEREST_RULES = {
    "ai_data": r"\bAI\b|인공지능|빅\s*데이터|데이터\s*(?:분석|사이언스|과학|엔지니어)",
    "software": r"소프트웨어|개발자|코딩|프로그래밍|\bSW\b|해커톤|앱\s*개발",
    "security": r"정보\s*보안|사이버\s*보안|해킹",
    "electronics_hw": r"전자|반도체|하드웨어|전기\s*공학|임베디드",
    "mechanical_manufacturing": r"기계|제조|생산\s*(?:관리|직)|스마트\s*팩토리",
    "construction_spatial": r"건설|토목|공간정보|드론|측량",
    "design": r"디자인",
    "media_content": r"영상|미디어|콘텐츠|방송|취재|기자(?!단|재)",
    "business_marketing": r"마케팅|경영|비즈니스|세일즈|영업(?!일|\s*시간)",
    "finance_accounting": r"금융|회계|세무|재무|Financ",
    "startup": r"창업",
    "global_language": r"해외|외국어|어학|글로벌|교환\s*학생|유학(?!생)|일본어|중국어",  # '외국인 유학생'은 제외
    "education_welfare": r"유아\s*교육|사회복지|청소년|상담사|(?<!창업)보육",
    "health": r"보건의료|의료|간호",
    "culture_arts": r"문화|예술|공연|음악|문학|글쓰기",
    "sports": r"스포츠|체육",
    "public_service": PUBLIC_ORG,
    "volunteering": r"봉사",
}

ROLE_RULES = {
    "software_developer": r"개발자|소프트웨어|코딩|프로그래밍|해커톤|앱\s*개발|웹\s*개발",
    "data_ai": r"데이터\s*(?:분석|엔지니어|사이언스)|인공지능|머신\s*러닝|딥\s*러닝|AI\s*(?:개발|모델|엔지니어|서비스|경진|해커톤)",
    "security_engineer": r"정보\s*보안|보안\s*(?:엔지니어|전문)|해킹|CTF",
    "hw_engineer": r"반도체|임베디드|전자\s*회로|전기\s*기사",
    "mechanical_engineer": r"기계\s*설계|\bCAD\b|스마트\s*팩토리|생산\s*(?:관리|직)",
    "civil_engineer": r"토목|건설\s*(?:현장|기술)|측량",
    "designer": r"디자이너|디자인\s*공모|\bUX\b|UI\s*디자인|시각\s*디자인",
    "content_creator": r"콘텐츠\s*제작|영상\s*(?:제작|편집|공모)|크리에이터|유튜브|숏폼|취재|기자(?!단|재)",
    "marketer": r"마케터|마케팅|서포터즈|홍보\s*(?:대사|기자단)|세일즈|영업(?!일|\s*시간)",
    "office_admin": r"사무원|경영\s*지원|사무\s*보조|행정\s*(?:직원|보조|인턴)",
    "accountant": r"회계|세무|재무|Financial",
    "service": r"승무원|(?:항공|공항)\s*서비스|호텔\s*(?:리어|경영|서비스)|서비스직",
    "educator": r"교사|보육\s*교사|교육\s*봉사|학습\s*멘토|튜터",
    "social_worker": r"사회복지",
    "healthcare": r"간호|보건의료|병원\s*(?:행정|실습)",
    "public_official": PUBLIC_ORG,
    "artist": r"실용음악|작곡|연극|전시회",
    "entrepreneur": r"창업",
}

# 학과 관련성: 학과 이름이 그대로 나오거나(아래 analyze), 그 학과가 직접 다루는 분야어가 나올 때
MAJOR_RULES = {
    "mjc.computer_engineering": r"소프트웨어|코딩|프로그래밍|해커톤|앱\s*개발|웹\s*개발",
    "mjc.ai_game_software": r"게임|인공지능|AI\s*(?:개발|모델|서비스|경진|해커톤)",
    "mjc.computer_security": r"정보\s*보안|사이버\s*보안|해킹|CTF",
    "mjc.electronic_engineering": r"반도체|전자\s*회로|임베디드",
    "mjc.information_communication": r"정보\s*통신|네트워크\s*(?:관리|엔지니어)|통신\s*기술",
    "mjc.mechanical_engineering": r"기계\s*설계|\bCAD\b|스마트\s*팩토리",
    "mjc.industrial_management": r"품질\s*관리|생산\s*관리|산업\s*경영",
    "mjc.electrical_engineering": r"전기\s*(?:기사|설비|공사)",
    "mjc.civil_engineering": r"토목|건설\s*(?:현장|기술)",
    "mjc.cadastral_spatial_info": r"공간\s*정보|\bGIS\b|측량|지적\s*(?:측량|정보)",
    "mjc.drone_information": r"드론",
    "mjc.business_administration": r"마케팅|경영\s*(?:전략|컨설팅)|비즈니스\s*모델",
    "mjc.tax_accounting": r"회계|세무",
    "mjc.real_estate": r"부동산",
    "mjc.social_welfare": r"사회복지",
    "mjc.public_administration": r"공무원|공공\s*행정",
    "mjc.aviation_service": r"항공\s*서비스|승무원|항공사",
    "mjc.chinese_business": r"중국어|\bHSK\b",
    "mjc.japanese": r"일본어|\bJLPT\b|일본",
    "mjc.creative_writing": r"글쓰기|문예|시나리오|웹소설",
    "mjc.early_childhood_education": r"유아|(?<!창업)보육",
    "mjc.youth_education_counseling": r"청소년",
    "mjc.industrial_design": r"제품\s*디자인|산업\s*디자인",
    "mjc.fashion_living_design": r"패션|리빙",
    "mjc.communication_design": r"시각\s*디자인|광고\s*디자인|편집\s*디자인",
    "mjc.ai_media_design": r"영상\s*(?:제작|편집)|모션\s*그래픽|미디어\s*디자인",
    "mjc.sports": r"스포츠|체육",
    "mjc.beauty_management": r"뷰티|메이크업|헤어",
    "mjc.health_information": r"보건의료|의무\s*기록|병원\s*행정",
    "mjc.applied_music": r"실용음악|밴드|작곡",
    "mjc.theater_film": r"연극|영화|연기",
}

START_DEADLINE = re.compile(r"신청\s*기간|접수\s*기간|모집\s*기간|공모\s*기간|원서\s*접수|신청\s*기한|접수\s*기한|제출\s*기한|마감|까지")
ACTIVITY = re.compile(
    r"활동\s*기간|교육\s*기간|운영\s*기간|행사\s*기간|연수\s*기간|근로\s*기간|근무\s*기간|실습\s*기간|계약\s*기간|파견\s*기간"
)
# 활동 기간 줄의 '~ 12.14.(월)까지'는 신청 마감이 아니다. 신청·접수를 함께 말할 때만 마감으로 본다.
APPLY = re.compile(r"신청|접수|모집|공모|원서|제출")


def is_activity_line(line: str) -> bool:
    return bool(ACTIVITY.search(line)) and not APPLY.search(line)


NOTE = re.compile(r"선착순|예산\s*소진|조기\s*마감")

GRADE_RANGE = re.compile(r"([1-4])\s*[~\-–]\s*([1-4])\s*학년")
GRADE_LIST = re.compile(r"([1-4])\s*[,·]\s*([1-4])\s*학년")
GRADE_ONE = re.compile(r"(?<![~\-–,·\d])([1-4])\s*학년\s*(?:만|대상|재학생|학생)")
UNIVERSITY = re.compile(r"우리\s*대학|본교")
# '분량 제한 없음' 같은 문구는 지원 자격이 아니다. 대상·자격에 대한 제한 없음만 본다.
UNRESTRICTED = re.compile(
    r"누구나|(?:학년|학과|전공|자격|대상|지원|참여|신청)\s*제한\s*없|제한\s*없이\s*(?:누구나|지원|참여|신청)|학년\s*무관|전공\s*무관"
)
UNRESOLVED = re.compile(r"평점|학점|성적|소득|연령|나이|만\s*\d+\s*세|우대|요건|거주|주민등록|소재|출신|국적")
# 재학·휴학·졸업 밖의 학적 (같은 줄에 있으면 재학 상태 조건으로 만들지 않는다)
OTHER_STATUS = re.compile(r"복학|입학\s*예정|편입|재입학|신입생")
# 고졸 이상 학력: 대학생은 재학·휴학·졸업 모두 갖춘다 ('고등학교 졸업예정자'만은 해당 없음) (D-023)
HIGH_SCHOOL_OR_MORE = re.compile(r"고등학교\s*졸업(?:자|\s*이상|\s*학력)|고졸\s*(?:이상|자|학력)")
# 제출 서류 목록(성적증명서 등)과 '성적에 관계없이'는 지원 조건이 아니다. 혜택·출결·성적 조회 안내도 (D-023)
NOT_CONDITION = re.compile(r"서류|증명서|확인서|사본|신청서|관계\s*없이|무관(?!심)|혜택|마일리지|결석|출석|성적\s*(?:조회|처리|입력)|이의\s*신청")
# 학적·학년·학과를 빼는 말('휴학생은 추천 불가', '휴학생 제외'). 이런 줄을 허용 조건으로 읽으면 판정이 뒤집힌다
EXCLUDES = re.compile(r"(?:재학생|휴학생|졸업생|졸업자|학년|학과|본교|우리\s*대학)[^,/()]{0,20}?(?:불가|제외|할\s*수\s*없)")
SEE_ATTACHMENT = re.compile(r"(?:첨부|붙임|모집요강)[^\n]{0,10}참(?:조|고)")

# ---------- 미해석 조건 정리 (D-015) ----------

PREFERRED_NOTE = "우대 사항"  # unresolved_condition.note: 지원 자격이 아니라 갖추면 유리한 조건
_ENUM = re.compile(r"^\s*(?:\(?\d{1,2}[.)]\s*|[①-⑳]\s*|[○●◦•ㆍᆞ·\-*※□■▶▷◎◆◇./]\s*|[가-하][.)]\s+)+")
_LABEL = re.compile(r"^([^\d/:：]{1,12}?)\s*(?:\s/\s|[:：])\s*(.+)$")  # '항목 이름 / 값', '항목 이름: 값'
_HEADING_WORD = re.compile(r"(?:지원|응시|참가|신청|자격|요건|조건|대상|우대|사항|필수|공통|분야별|직무별|기타)+")
# 조건 문구 자체가 우대를 말하는 경우 ('…자 우대', '…우대함'). '우대가점', '우대사항은 … 충족' 같은 말은 아님
_ENDS_PREFERRED = re.compile(r"우대(?:함|합니다)?\.?\s*$")
# 필수 조건을 말하는 줄. 우대 항목이 여기서 끝나고, 이 줄은 우대 사항이 아니다
_REQUIRED = re.compile(r"필수|(?:지원|응시)\s*자격\s*[:：]|자격\s*요건\s*[:：]")
_TOP_HEADING = re.compile(r"^\s*\d{1,2}\.\s")


def _is_heading(text: str) -> bool:
    """'지원자격 및 우대사항', '자격요건:'처럼 항목 이름만 있는 줄."""
    words = [w for w in re.split(r"[\s·/,:()및]+", text) if w]
    return bool(words) and all(_HEADING_WORD.fullmatch(w) for w in words)


def condition_text(line: str) -> tuple[str | None, bool]:
    """(번호·기호·항목 이름을 뗀 조건 문구, 항목 이름이 '우대'였는지). 제목만 있는 줄이면 문구는 None.

    문구는 원문 줄의 일부라 근거 검증(원문에 있는가)을 그대로 통과한다.
    """
    text = _ENUM.sub("", line).strip()
    preferred = False
    if (m := _LABEL.match(text)) and _is_heading(m[1]):
        preferred = "우대" in m[1]
        text = _ENUM.sub("", m[2]).strip()
    if not text or _is_heading(text) or re.match(r"없음\b", text):  # '우대사항: 없음'
        return None, preferred
    return text, preferred


def _preferred_lines(lines: list[str]) -> list[str]:
    """'우대사항' 항목 아래 줄들. 다음 번호 제목, '지원자격' 같은 다른 항목, 이미지 설명이 나오면 끝난다."""
    out, section = [], None
    for line in lines:
        text = _ENUM.sub("", line).strip()
        m = _LABEL.match(text)
        head = m[1] if m else text
        if _is_heading(head):
            pref, req = "우대" in head, bool(re.search(r"자격|요건|조건|대상|공통", head))
            section = "pref" if pref and not req else None
            if m and section:
                out.append(m[2])
        elif _TOP_HEADING.match(line) or _REQUIRED.search(line) or line == "[이미지 설명]":
            section = None
        elif section:
            out.append(text)
    return out


def tidy_unresolved(items: list[dict], lines: list[str]) -> tuple[list[dict], bool]:
    """미해석 조건을 정리한다: 번호·기호 떼기, 제목 줄 빼기, 같은 문구 하나로, 우대 사항 표시.

    돌려주는 bool은 제목 줄을 뺐는지다. 제목 아래 조건을 다 읽었다고 볼 수 없으니 완전성을 막는 데 쓴다.
    """
    preferred_lines = _preferred_lines(lines)
    out: dict[str, dict] = {}
    dropped = False
    for item in items:
        text, label_preferred = condition_text(item["evidence"])
        if text is None:
            dropped = True
            continue
        preferred = not _REQUIRED.search(item["evidence"]) and (
            label_preferred or bool(_ENDS_PREFERRED.search(text)) or any(text in p for p in preferred_lines)
        )
        key = re.sub(r"\s+", "", text)
        if key in out:
            if preferred:
                out[key]["note"] = PREFERRED_NOTE
            continue
        out[key] = {"evidence": text, "note": PREFERRED_NOTE if preferred else item["note"]}
    return list(out.values()), dropped


# ---------- LLM 미해석 조건 거르기 (D-023) ----------

# 신청자 본인이 갖춰야 하는 조건을 말하는 낱말. 프로필로 판정하지 못하는 속성들
PERSONAL_HINT = re.compile(
    r"평점|학점|성적|백분위|이수(?:자|한|했|\s*중)"
    r"|소득|학자금\s*지원|\d\s*구간|분위|기초\s*생활|차상위|저소득|수급"
    r"|연령|나이|만\s*\d+\s*세|\d+\s*세\s*(?:이하|이상|미만)|출생"
    r"|거주|주민등록|주소지|출신|국적|외국인|유학생"
    r"|토익|TOEIC|TOEFL|IELTS|JLPT|HSK|OPIc|어학\s*(?:성적|점수)|자격증|면허|소지|보유"
    r"|장애|유공|보훈|북한\s*이탈|다문화|한부모|다자녀|자립\s*준비|보호\s*종료|사회적\s*배려|미혼|병역|군필|결격"
    r"|재직|직계|임직원|경력|경험이?\s*(?:있는|없는)|근속|추천(?:자|을|받)"
    r"|(?:근무|근로|운전)\s*(?:가능|할\s*수)|(?:신청|입소|승인)한\s*(?:학생|자)|승인자"
    r"|중복\s*(?:수혜|지원|신청|참여)\S*\s*불가|(?:자|생|대상)[은는]?\s*제외"
    r"|학적|복학|편입|재입학|신입생|입학\s*예정|대학원생",
    re.I,
)
# 프로필로 판정하는 학년·학적·학과 낱말. 이미 조건으로 읽은 줄 안의 문구면 다시 묻지 않는다
PROFILE_HINT = re.compile(r"(?<!\d)[1-4]\s*학년(?!도)|재학|휴학|졸업|전공\s*심화|(?:학과|전공)\s*(?:학생|소속)")
# 자격처럼 보여도 지원 자격이 아닌 문장: 팀 구성, 혜택, 제출·안내·요청
NOT_ELIGIBILITY = re.compile(
    r"팀|마일리지|포인트|환급|적립|인정|강좌|제출|준비|바랍니다|주세요|주시기|주셔야|부탁|유의|여러분|고자"
)
# 대상을 넓히는 말('유학생 포함', '전공심화 학생 신청 가능'). 제한을 함께 말하면 조건으로 둔다
OPEN_TO = re.compile(r"포함\s*$|가능(?:한|함|합니다)?\s*[!.]?\s*$")
LIMIT = re.compile(r"만\s*(?:가능|신청|지원)|불가|이상|이하|이내|미만")


def _compact(text: str) -> str:
    return re.sub(r"\s+", "", text)


def is_llm_condition(text: str, conditions: list[dict], unresolved: list[dict], lines: list[str] = ()) -> bool:
    """LLM이 낸 미해석 조건을 받을지. 신청자 본인 조건과 원문 '우대사항' 항목 아래 줄만 받고, 이미 보이는 문구는 다시 내지 않는다.

    LLM은 일정·혜택·제출 방법·팀 구성·주제·대상 설명도 조건으로 내곤 한다. 받는 쪽을 좁게 둔다.
    우대 사항은 지원 자격과 따로 묶여 확인 필요 수에 들지 않으니(D-015) 낱말과 관계없이 받는다.
    """
    if NOT_ELIGIBILITY.search(text) or NOT_CONDITION.search(text):
        return False
    if OPEN_TO.search(text) and not LIMIT.search(text):
        return False
    key = _compact(text)
    if any(key in _compact(u["evidence"]) for u in unresolved):
        return False  # 규칙이 이미 그 줄을 확인 항목으로 냈다
    if lines and any(key in _compact(p) for p in _preferred_lines(lines)):
        return True
    if PERSONAL_HINT.search(text):
        return True
    # 이미 재학 상태·학년 조건으로 읽은 줄의 일부면 빼고, 따로 나온 학적 문구만 받는다
    return bool(PROFILE_HINT.search(text)) and not any(key in _compact(c["evidence"]) for c in conditions)


def _lines(raw: dict) -> list[str]:
    return [line.strip() for line in raw["body_text"].splitlines() if line.strip()]


def _unread_images(raw: dict) -> int:
    """본문 이미지 중 대체텍스트로 내용을 읽지 못한 수 (D-014)."""
    fields = raw["source_fields"]
    return (fields.get("body_image_count") or 0) - (fields.get("body_image_text_count") or 0)


def _codes(rules: dict[str, str], text: str, allowed: set[str]) -> list[str]:
    return [code for code, pattern in rules.items() if code in allowed and re.search(pattern, text)]


class RuleBasedAnalyzer:
    version = ANALYSIS_VERSION

    def analyze(self, raw: dict, source: SourceConfig) -> dict:
        title, lines = raw["title"], _lines(raw)
        text = title + "\n" + "\n".join(lines)
        admin = bool((JOB_BOARD_ADMIN_TITLE if raw["source_id"] in JOB_BOARDS else ADMIN_TITLE).search(title))
        category = "admin_notice" if admin else self._category(TAG_NOISE.sub(" ", title), TAG_NOISE.sub(" ", text))
        tag_source = title if category in TITLE_ONLY_TAG_CATEGORIES else text
        tag_text = "" if admin else TAG_NOISE.sub(" ", tag_source)  # 비학생 공지는 꼬리표 없음
        majors = {m["id"] for m in _dictionary("majors")}
        named = [m["id"] for m in _dictionary("majors") if m["name_ko"] in tag_text]
        return {
            "summary": None,  # 검증된 요약은 LLM 단계 이후
            "category": category,
            "interest_tags": _codes(INTEREST_RULES, tag_text, {i["id"] for i in _dictionary("interests")}),
            "related_majors": named + [c for c in _codes(MAJOR_RULES, tag_text, majors) if c not in named],
            "related_roles": _codes(ROLE_RULES, tag_text, {r["id"] for r in _dictionary("roles")}),
            **self._dates(lines, source),
            "eligibility": self._eligibility(raw, lines, source),
        }

    @staticmethod
    def _category(title: str, text: str) -> str:
        for target in (title, text):
            for code, pattern in CATEGORY_RULES:
                if re.search(pattern, target):
                    return code
        return "other"

    @staticmethod
    def _dates(lines: list[str], source: SourceConfig) -> dict:
        out = {"application_start": None, "application_deadline": None, "deadline_note": None, "activity_period": None}
        tz = source.timezone
        for line in lines:
            if out["deadline_note"] is None and NOTE.search(line):
                out["deadline_note"] = line
            start, end = parse_line(line)
            if start is None:
                continue
            if out["application_deadline"] is None and START_DEADLINE.search(line) and not is_activity_line(line):
                if end:
                    out["application_start"] = date_info(start, line, tz)
                    out["application_deadline"] = date_info(end, line, tz)
                else:
                    out["application_deadline"] = date_info(start, line, tz)
            elif out["activity_period"] is None and ACTIVITY.search(line):
                out["activity_period"] = {
                    "start": date_info(start, line, tz),
                    "end": date_info(end, line, tz) if end else None,
                    "evidence": line,
                }
        return out

    @staticmethod
    def _eligibility(raw: dict, lines: list[str], source: SourceConfig) -> dict:
        conditions, unresolved = [], []
        majors = _dictionary("majors")

        def add(field, operator, value, evidence):
            if EXCLUDES.search(evidence):  # 누구를 빼는 줄은 자동 판정하지 않고 직접 확인으로 (D-023)
                unresolved.append({"evidence": evidence, "note": None})
                return
            if not any(c["field"] == field for c in conditions):
                conditions.append({"field": field, "operator": operator, "value": value, "evidence": evidence, "validation_status": "validated"})

        unrestricted_line = None
        for line in lines:
            if m := GRADE_RANGE.search(line):
                lo, hi = sorted((int(m[1]), int(m[2])))
                add("grade", "in", list(range(lo, hi + 1)), line)
            elif m := GRADE_LIST.search(line):
                add("grade", "in", sorted({int(m[1]), int(m[2])}), line)
            elif m := GRADE_ONE.search(line):
                add("grade", "eq", int(m[1]), line)

            statuses = [s for s, p in (("enrolled", r"재학생|재\s*[·ㆍ･,/]\s*휴학생"), ("on_leave", r"휴학생"), ("graduated", r"졸업생|졸업자")) if re.search(p, line)]
            if HIGH_SCHOOL_OR_MORE.search(line) and not NOT_CONDITION.search(line):
                add("enrollment_status", "in", ["enrolled", "on_leave", "graduated"], line)
            elif statuses and OTHER_STATUS.search(line):
                unresolved.append({"evidence": line, "note": None})  # 복학생·입학예정자 등은 프로필 재학 상태로 판정할 수 없다
            elif statuses:
                add("enrollment_status", "eq" if len(statuses) == 1 else "in", statuses[0] if len(statuses) == 1 else statuses, line)

            if source.university_id and UNIVERSITY.search(line):
                add("university_id", "eq", source.university_id, line)

            named = [m["id"] for m in majors if m["name_ko"] in line and re.search(re.escape(m["name_ko"]) + r"\s*(?:재학생|학생|대상|소속)", line)]
            if named:
                add("major_id", "eq" if len(named) == 1 else "in", named[0] if len(named) == 1 else named, line)

            if (UNRESOLVED.search(line) and not NOT_CONDITION.search(line)) or SEE_ATTACHMENT.search(line):
                unresolved.append({"evidence": line, "note": None})
            if unrestricted_line is None and UNRESTRICTED.search(line):
                unrestricted_line = line

        unresolved, dropped_heading = tidy_unresolved(unresolved, lines)
        explicit = unrestricted_line is not None and not conditions
        complete = (
            (bool(conditions) or explicit)
            and not unresolved
            and not dropped_heading
            and not raw["attachments"]
            and not _unread_images(raw)  # 포스터 이미지 속 조건은 읽지 못함 (대체텍스트로 읽은 이미지는 제외)
        )
        return {
            "conditions": conditions,
            "unresolved_conditions": unresolved,
            "extraction_complete": complete,
            "explicitly_unrestricted": explicit,
            "unrestricted_evidence": unrestricted_line if explicit else None,
        }
