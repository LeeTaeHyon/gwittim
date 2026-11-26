"""규칙 기반 분석기: 결정적 파싱만으로 RawNotice에서 구조화 정보를 뽑는다.

LLM 분석기(W8 이후)는 같은 Analyzer 인터페이스로 교체·보강한다. 규칙 분석기는 스스로 추출이 완전하다고
판단할 근거가 약하므로, 첨부·미해석 조건·조건 미발견이 있으면 extraction_complete=false로 둔다.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from functools import cache
from pathlib import Path
from typing import Protocol

from backend.contracts import CONTRACTS_DIR
from backend.sources import SourceConfig

from .dates import date_info, parse_line

ANALYSIS_VERSION = "rule-0.13"  # 0.13: 항목 제한 없음은 구절 전체일 때만(긴 줄을 통째로 바꾸지 않음). 0.12(0.11은 되돌린 자체 모델 실험이 썼다): 필수·우대·모호를 원문 위치로 나눠 우대·항목 제한 없음은 판정·완전성에서 제외, 필수·혼합 제목은 아래 읽은 항목으로 완전성 판단(D-056). 0.10: 졸업 예정자 줄은 재학 상태 조건으로 만들지 않고 직접 확인(D-046). 0.9: 재학상태 여러 값·기간형 신청 끝날짜·신청자 조건 줄·행정 공지 조건 제외·학년 전체 나열 무시·카테고리 보강. 0.8: 미해석 조건이 남으면 제한 없음 아님, 제한 없음 줄은 '무관' 면제 없음. 0.7: LLM 미해석 조건은 신청자 본인 조건만(D-023). 0.6: 미해석 조건 정리·우대 사항 표시(D-015). 0.5: 근로·근무 기간은 마감 아님. 0.4: 이미지 대체텍스트, 두 자리 연도(D-014). 0.3: 장학·채용·근로 게시판(D-013). 0.2: 부서명 오탐 제거, 직무·학과 키워드, admin_notice


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
    r"(?:교수|교원|강사|조교)\s*(?:초빙|공개\s*채용|채용)|교직원|정기\s*점검|안전\s*진단|주차장|청소\s*작업|보건실"
    r"|국민\s*행동\s*요령|라이선스|입찰|용역|휴무|정전|단수|시스템\s*점검"
    r"|전산\s*(?:시스템|서비스)|서비스\s*(?:일시\s*)?중단|세척기|복사기|프린터|정수기|자판기|엘리베이터|냉난방"
)
# '직원 채용'은 학교 직원일 수도, 학생이 지원하는 기업 채용일 수도 있다. 학생·인턴·캠퍼스 리크루팅 같은 말이 제목에 있으면 행정 공지로 보지 않는다.
STAFF_TITLE = re.compile(r"직원\s*(?:초빙|공개\s*채용|채용|모집)")
STUDENT_TARGET_TITLE = re.compile(r"학생|재학생|졸업생|인턴|신입|캠퍼스|리크루팅|현장\s*실습")
# 업체를 상대로 한 계약 공고: 마감이 학생 신청 마감이 아니다. (교원·직원 채용의 접수 마감은 그 채용의 마감이라 남긴다)
VENDOR_TITLE = re.compile(r"입찰|용역|견적|수의\s*계약")
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
    ("volunteer", r"(?:자원\s*)?봉사자\s*(?:모집|지원)|봉사단\s*모집"),  # '놀이대회 자원봉사자 모집'은 대회가 아니다
    ("contest", r"공모전|경진대회|해커톤|대회"),
    ("scholarship", r"장학"),
    ("internship", r"인턴|현장실습"),
    ("job", r"채용|구인|근로\s*학생"),
    ("volunteer", r"봉사"),
    ("global", r"해외|연수|교환학생|유학(?!생)"),
    ("startup", r"창업"),
    ("education_program", r"특강"),  # '역량기반 … 특강'은 비교과 안내가 아니라 교육 프로그램
    ("extracurricular", r"비교과|마일리지|역량"),
    ("education_program", r"교육생|강좌|과정|교육|부트\s*캠프|워크\s*[숍샵]|아카데미"),
    ("event", r"행사|박람회|축제|설명회|포럼|바자회"),
    ("academic", r"수강\s*(?:신청|정정|철회)|계절\s*학기|학사|성적|졸업|등록금|강의평가|시험"),  # '콘텐츠 수강 안내'는 학사 안내가 아님
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


# '2026.11.30.(월) 10:00부터 …'처럼 시작만 읽힌 줄의 날짜는 마감이 아니다 (끝 날짜가 읽히면 범위로 본다)
FROM_START = re.compile(r"\d\s*(?:\([월화수목금토일]\))?\s*(?:,\s*\d{1,2}:\d{2})?\s*부터")

NOTE = re.compile(r"선착순|예산\s*소진|조기\s*마감")

GRADE_RANGE = re.compile(r"([1-4])\s*[~\-–]\s*([1-4])\s*학년")
GRADE_LIST = re.compile(r"(?<![\d~\-–])([1-4](?:\s*[,·]\s*[1-4])+)\s*학년")
GRADE_ONE = re.compile(r"(?<![~\-–,·\d])([1-4])\s*학년\s*(?:만|대상|재학생|학생)")
UNIVERSITY = re.compile(r"우리\s*대학|본교")
# '분량 제한 없음' 같은 문구는 지원 자격이 아니다. 대상·자격에 대한 제한 없음만 본다.
# 전체 제한 없음: 지원 대상 전체에 제한이 없다고 밝힌 문구. explicitly_unrestricted의 근거가 된다 (D-056)
UNRESTRICTED_ALL = re.compile(r"누구나|(?:자격|대상|지원|참여|신청)\s*제한\s*없|제한\s*없이\s*(?:지원|참여|신청)")
# 항목별 제한 없음: 학년·학과·전공 하나에만 제한이 없다는 문구. 나머지 자격이 열렸다는 근거는 아니다
_ITEM_WORD = r"(?:학년|학과|전공|학력)"
UNRESTRICTED_ITEM = re.compile(rf"{_ITEM_WORD}(?:\s*(?:[·ㆍ,/]|및|과|와)\s*{_ITEM_WORD})*\s*(?:제한\s*없(?:음|이|습니다)?|무관)")
# 항목 제한 없음 구절 바로 뒤에 붙은 예외: '(특정 모집 부문 제외)', ', 단, …'. 예외가 붙으면 구절 전체를 직접 확인으로 둔다 (D-056 3.4)
_EXCEPTION = re.compile(r"\s*(?:[(（][^()（）]*(?:제외|단[,，\s])[^()（）]*[)）]|[,，]?\s*(?:단|다만)[,，\s][^,，.]*)")
UNRESTRICTED = re.compile(UNRESTRICTED_ALL.pattern + "|" + UNRESTRICTED_ITEM.pattern)
UNRESOLVED = re.compile(r"평점|학점|성적|소득|연령|나이|만\s*\d+\s*세|우대|요건|거주|주민등록|소재|출신|국적")
# 신청자·작품이 갖춰야 하거나 피해야 하는 조건 줄: 성적 기준, 채플 출석 통과, 초과학기, 표절·기존 발표·수상작 응모 불가.
# '출석'·'성적' 낱말 때문에 안내 문구로 면제되지 않게 따로 본다
APPLICANT_CONDITION = re.compile(
    r"(?:성적|평점|학점|백분위)[^\n]{0,25}?(?:이상|이하|미만|초과|\d\s*점)"
    r"|채플[^\n]{0,15}(?:통과|이수|출석)|출석[^\n]{0,8}(?:통과|이수)"
    r"|초과\s*학기\s*(?:생|자)|정규\s*학기[^\n]{0,10}초과"
    r"|(?:표절|도용|기존\s*발표|수상\s*(?:이력|경력|작)|타\s*공모전)[^\n]{0,60}?(?:불가|없는|없을|없습니다|수\s*없|제외|않은|아니)"
)
# 학생·졸업생을 함께 말하는 표현 ('학생 또는 졸업생'): 재학생 낱말이 없어도 재학 중인 학생과 졸업생 둘 다다
STUDENT_OR_GRADUATE = re.compile(r"(?<![재휴대])학생\s*(?:또는|혹은|및|,|/)\s*졸업(?:생|자)|졸업(?:생|자)\s*(?:또는|혹은|및|,|/)\s*(?<![재휴대])학생")
# 재학·휴학·졸업 밖의 학적 (같은 줄에 있으면 재학 상태 조건으로 만들지 않는다)
# '졸업 예정자'는 재학생 중 일부라 프로필 재학 상태(재학·휴학·졸업)로 판정할 수 없다. '기졸업자 또는 졸업예정자'를
# 졸업생만으로 읽으면 졸업 예정인 재학생이 미충족이 된다 (D-046). '재학생(졸업예정자 포함)'처럼 넓히는 말은 그대로 둔다
OTHER_STATUS = re.compile(r"복학|입학\s*예정|편입|재입학|신입생|졸업\s*예정(?!자?\s*(?:도\s*)?포함)")
# 고졸 이상 학력: 대학생은 재학·휴학·졸업 모두 갖춘다 ('고등학교 졸업예정자'만은 해당 없음) (D-023)
HIGH_SCHOOL_OR_MORE = re.compile(r"고등학교\s*졸업(?:자|\s*이상|\s*학력)|고졸\s*(?:이상|자|학력)")
# 제출 서류 목록(성적증명서 등)과 '성적에 관계없이'는 지원 조건이 아니다. 혜택·출결·성적 조회 안내도 (D-023)
NOT_CONDITION = re.compile(r"서류|증명서|확인서|사본|신청서|관계\s*없이|무관(?!심)|혜택|마일리지|결석|출석|성적\s*(?:조회|처리|입력)|이의\s*신청")
# 학적·학년·학과를 빼는 말('휴학생은 추천 불가', '휴학생 제외'). 이런 줄을 허용 조건으로 읽으면 판정이 뒤집힌다
EXCLUDES = re.compile(r"(?:재학생|휴학생|졸업생|졸업자|학년|학과|본교|우리\s*대학)[^,/()]{0,20}?(?:불가|제외|할\s*수\s*없)")
SEE_ATTACHMENT = re.compile(r"(?:첨부|붙임|모집요강)[^\n]{0,10}참(?:조|고)")

# ---------- 문구의 역할: 필수·우대·모호 (D-015, D-056) ----------

# unresolved_condition.note에 정해 두고 쓰는 값. 둘 다 지원 자격이 아니라 판정·완전성·확인 개수에 넣지 않는다.
PREFERRED_NOTE = "우대 사항"  # 갖추면 유리한 조건
NO_LIMIT_NOTE = "항목 제한 없음"  # '학년 무관'처럼 한 항목에만 제한이 없다는 문구
FLAG_NOTES = (PREFERRED_NOTE, NO_LIMIT_NOTE)

_ENUM = re.compile(r"^\s*(?:#{1,6}\s*|\(?\d{1,2}[.)]\s*|[①-⑳]\s*|[○●◦•ㆍᆞ·\-*※□■▶▷◎◆◇./]\s*|[가-하][.)]\s+)+")
_LABEL = re.compile(r"^([^\d/:：]{1,12}?)\s*(?:\s/\s|[:：])\s*(.+)$")  # '항목 이름 / 값', '항목 이름: 값'
_HEADING_WORD = re.compile(r"(?:지원|응시|참가|신청|자격|요건|조건|대상|우대|사항|필수|공통|분야별|직무별|기타)+")
_REQ_WORD = re.compile(r"자격|요건|조건|대상|공통|필수")
# 필수 조건을 말하는 줄. 우대 구역이 여기서 끝나고, 이 줄은 우대 사항이 아니다
_REQUIRED = re.compile(r"필수|(?:지원|응시)\s*자격\s*[:：]|자격\s*요건\s*[:：]")
# 번호 제목: 점이 없어도 된다('5 근무조건'), '## 모집 개요'도 (D-056 3.1)
_TOP_HEADING = re.compile(r"^\s*(?:#{1,6}\s*\S|\d{1,2}\.\s|\d{1,2}\s+(?=[가-힣A-Za-z]))")
_BRACKET_TITLE = re.compile(r"[\[【<]\s*(.+?)\s*[\]】>]\s*[:：]?")
# 구절의 역할 표지 (3.2). 목록에 없는 표현은 모호로 다룬다 (테스트로 고정)
_PREF_END = re.compile(r"우대(?:함|합니다|됩니다|해요)?[.!]?$")
_REQ_END = re.compile(
    r"(?:대상(?:자|입니다)?|한함|한정|필수|[가-힣\d]만(?:\s*(?:지원|신청|참여))?(?:\s*가능(?:함|합니다)?)?"
    r"|(?:지원|참여)\s*가능(?:함|합니다)?)[.!]?$"
)
_PAREN = re.compile(r"[(（]([^()（）]*)[)）]")
_SEPARATORS = ",，;；"
# 소제목에 쓰는 기호. '-', '•', '※'는 목록 기호라 넣지 않는다
_TITLE_MARK = re.compile(r"^\s*(?:[■□▶▷◆◇◎●○【]|\(?\d{1,2}\)|[①-⑳])\s*")
SHORT_TITLE = 14  # 이 글자 수 이하이고 기호·조건 단서가 없는 줄은 새 제목으로 본다
_TRIM = " ,;，；·"


def _is_heading(text: str) -> bool:
    """'지원자격 및 우대사항', '자격요건:'처럼 항목 이름만 있는 줄."""
    words = [w for w in re.split(r"[\s·/,:()및]+", text) if w]
    return bool(words) and all(_HEADING_WORD.fullmatch(w) for w in words)


def _heading_kind(head: str) -> str:
    """항목 이름의 종류: required(자격·요건·조건·대상), preferred(우대만), mixed(둘 다), neutral."""
    pref = "우대" in head
    # '우대조건'·'우대 사항'의 조건·사항은 우대의 이름이지 필수 표지가 아니다
    req = bool(_REQ_WORD.search(re.sub(r"우대\s*(?:조건|사항|요건|자격)?", "", head)))
    return "mixed" if pref and req else "preferred" if pref else "required" if req else "neutral"


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


@dataclass
class _Seg:
    role: str  # required | preferred | ambiguous
    text: str  # 구절. 원문 줄의 부분 문자열 (분리하지 않은 필수 구절은 줄 전체)


@dataclass
class _Info:
    line: str
    kind: str  # heading | image | body
    heading: str = ""  # kind가 heading일 때 종류
    top: bool = False  # 번호 제목('3. 신청 방법') 꼴
    segs: list[_Seg] = field(default_factory=list)
    split: bool = False  # 한 줄을 역할별 구절로 나눴는지
    sect: str | None = None  # 이 줄이 속한 구역의 종류(독립 제목이 연 구역). 항목 이름은 구역이 아니다
    label_ctx: str | None = None  # 줄 앞 항목 이름의 종류(그 줄에만 적용)
    listy: bool = False  # 목록 기호가 붙었거나 항목 이름이 붙은 줄(문장이 아니라 항목)


def _split_top(text: str) -> list[tuple[int, int]]:
    """괄호 밖 구두점으로 나눈 구절 범위."""
    out, depth, start = [], 0, 0
    for i, ch in enumerate(text):
        if ch in "([（［":
            depth += 1
        elif ch in ")]）］":
            depth = max(0, depth - 1)
        elif ch in _SEPARATORS and depth == 0:
            out.append((start, i))
            start = i + 1
    out.append((start, len(text)))
    return out


def _closing(phrase: str) -> str | None:
    p = phrase.strip()
    return "preferred" if _PREF_END.search(p) else "required" if _REQ_END.search(p) else None


def _segments(body: str, ctx: str | None) -> tuple[list[tuple[str, str]], bool]:
    """한 줄(항목 이름·번호를 뗀 문구)을 역할별 구절로 나눈다 (D-056 3.2).

    ctx는 줄의 문맥(항목 이름·구역): required, preferred, mixed, None. 반환: ([(역할, 구절)], 나눴는지).
    """
    parens = [m for m in _PAREN.finditer(body) if _PREF_END.search(m[1].strip())]
    if parens:
        prefs = [("preferred", m[1].strip()) for m in parens]
        pieces, pos = [], 0
        for m in parens:
            pieces.append(body[pos:m.start()])
            pos = m.end()
        pieces.append(body[pos:])
        outer = [t for t in (p.strip(_TRIM) for p in pieces) if t]
        if not outer:
            return prefs, True
        if any(_REQ_END.search(o) for o in outer) or ctx == "required":
            return [("required", o) for o in outer] + prefs, True
        return [("preferred" if ctx == "preferred" else "ambiguous", body)], False

    groups, start = [], 0  # 표지로 닫힌 구절 묶음 (kind, 시작, 끝). 닫히지 않은 구절은 다음 묶음에 붙는다
    for a, b in _split_top(body):
        if kind := _closing(body[a:b]):
            groups.append((kind, start, b))
            start = b + 1
    trailing = bool(body[start:].strip(_TRIM))
    prefs = [g for g in groups if g[0] == "preferred"]
    reqs = [g for g in groups if g[0] == "required"]
    if prefs:
        if reqs and not trailing:
            merged: list[list] = []
            for kind, a, b in groups:
                if merged and merged[-1][0] == kind:
                    merged[-1][2] = b
                else:
                    merged.append([kind, a, b])
            return [(k, body[a:b].strip(_TRIM)) for k, a, b in merged], True
        if not reqs and not trailing:
            return [("preferred", body[a:b].strip(_TRIM)) for _, a, b in groups], len(groups) > 1
        if not trailing or ctx == "preferred":
            return [("preferred", body)], False
        return [("ambiguous", body)], False  # 닫는 표지 없이 중간에 '우대'가 있음
    if "우대" in body:
        return [("preferred" if ctx == "preferred" else "ambiguous", body)], False
    if ctx == "preferred":
        return [("preferred", body)], False
    if ctx == "mixed" and not reqs:
        return [("ambiguous", body)], False
    return [("required", body)], False


def _unbracket(text: str) -> tuple[str, bool]:
    """'[자격요건]' 같은 괄호 제목의 알맹이와 괄호 제목이었는지. 끝의 역슬래시·공백은 뗀다."""
    t = re.sub(r"[\\\s]+$", "", text.strip())
    if m := _BRACKET_TITLE.fullmatch(t):
        return m[1], True
    return t, False


def _heading_of(text: str) -> str | None:
    """독립 제목이면 종류, 아니면 None."""
    t, _ = _unbracket(text)
    return _heading_kind(t) if _is_heading(t) else None


def read_lines(lines: list[str]) -> list[_Info]:
    """본문 줄마다 제목·본문 구분과 문구의 역할(필수·우대·모호)을 원문 위치로 정한다 (D-056 3.1).

    구역은 독립 제목 줄(괄호 제목 포함)만 연다. 항목 이름('우대사항 / …')은 그 줄에만 적용하고 구역을 열지 않는다.
    구역은 다음 독립 제목, 번호 제목, 이미지 설명, 필수 표지 줄, 조건 단서 없는 새 표 항목에서 끝난다.
    """
    infos: list[_Info] = []
    section = None
    for line in lines:
        text = _ENUM.sub("", line).strip()
        if line == "[이미지 설명]":
            section = None
            infos.append(_Info(line, "image"))
            continue
        top = bool(_TOP_HEADING.match(line))
        if (kind := _heading_of(text)) is not None:
            section = None if kind == "neutral" else kind
            infos.append(_Info(line, "heading", kind, top=top))
            continue
        if _TITLE_MARK.match(line) and ":" not in text and " / " not in text and len(text) <= SHORT_TITLE and not has_clue(text) and not SENTENCE_END.search(text):
            section = None  # '■ 모집 기간', '■ 시상내역', '1) 공간지원': 이름은 모르지만 새 소제목이다 (D-056 3.1)
            infos.append(_Info(line, "heading", "neutral", top=top))
            continue
        if top:
            section = None
        forced = bool(_REQUIRED.search(line))
        if forced:
            section = None
        body, label_ctx, table_item = text, None, False
        if m := _LABEL.match(text):
            name, bracket = _unbracket(m[1])
            value = _ENUM.sub("", m[2]).strip()
            if _is_heading(name):
                kind = _heading_kind(name)
                if bracket:  # '[우대사항] / 내용': 괄호 제목이 구역을 열고 내용은 그 구역의 첫 줄
                    section = None if kind == "neutral" else kind
                    body = value
                elif (value_kind := _heading_of(value)) is not None:  # '항목 이름 / [제목]': 뒤쪽이 제목
                    section = None if value_kind == "neutral" else value_kind
                    infos.append(_Info(line, "heading", value_kind, top=top))
                    continue
                else:
                    label_ctx = None if kind == "neutral" else kind
                    body = value
            else:
                # '채용구분 / 계약직', '근무지: 인천'. 'PLC / Sequence Control'처럼 한글이 없는 앞말은 항목 이름이 아니라 내용이다
                table_item = bool(re.search(r"[가-힣]", name))
        if table_item and not has_clue(text):
            section = None  # 조건 단서 없는 새 표 항목에서 구역이 끝난다
        elif m is None and not top and not _ENUM.match(line) and len(text) <= SHORT_TITLE and not has_clue(text):
            section = None  # 기호 없는 짧은 줄은 이름을 모르는 새 제목으로 보고 구역을 닫는다('참여 방법', '시상 내역')
        ctx = label_ctx or ("required" if forced else section)
        info = _Info(line, "body", top=top, sect=section, label_ctx=label_ctx, listy=bool(_ENUM.match(line)) or m is not None)
        if body:
            segs, info.split = _segments(body, ctx)
            info.segs = [_Seg(role, line if role == "required" and not info.split else t) for role, t in segs]
        infos.append(info)
    return infos


def _span(info: _Info, seg: _Seg) -> str:
    """구절이 들어 있는 원문 부분: 분리하지 않았으면 줄 전체 (근거 검증은 이 범위로 한다)."""
    return seg.text if info.split else info.line


def blocking_headings(infos: list[_Info]) -> bool:
    """필수·혼합 제목 아래에서 읽은 항목이 하나도 없는 제목이 있는지 (D-056 3.3). 있으면 완전성을 막는다.

    범위는 제목 다음 줄부터 다음 제목·번호 제목·이미지 설명 직전까지. 우대 전용 제목은 막지 않는다.
    """
    for i, info in enumerate(infos):
        if info.kind != "heading" or info.heading not in ("required", "mixed"):
            continue
        items = 0
        for nxt in infos[i + 1:]:
            if nxt.kind != "body" or nxt.top:
                break
            items += 1
        if not items:
            return True
    return False


def _flag(note: str | None) -> str | None:
    return note if note in FLAG_NOTES else None


def _locate_note(evidence: str, infos: list[_Info], note: str | None) -> str | None:
    """원문에서 문구가 나오는 위치로 표시를 정한다 (D-056 4). 우대 위치에만 나오면 우대, 필수·모호 위치에도 나오면 우대가 아님.

    항목별 제한 없음 문구면 항목 제한 없음. 원문에서 위치를 찾지 못하면 받은 표시를 그대로 둔다.
    """
    if _flag(note):
        return note
    text, _ = condition_text(evidence)
    if text is None:
        return note
    key = _compact(text)
    roles = {s.role for i in infos for s in i.segs if key in _compact(_span(i, s))}
    if not roles:  # 여러 구절에 걸친 문구: 줄 안의 모든 구절로 본다
        roles = {s.role for i in infos if key in _compact(i.line) for s in i.segs}
    if roles == {"preferred"}:
        return PREFERRED_NOTE
    # 문구 전체가 '전공·학년 무관' 같은 구절일 때만 항목 제한 없음이다. 긴 줄 안에 '무관'이 들어 있다고 줄 전체를 바꾸면
    # 같은 줄의 지원 대상('재학·휴학생, 졸업예정자')이 확인 항목에서 빠진다 (2026-11-26 운영 반영 뒤 확인)
    if UNRESTRICTED_ITEM.fullmatch(text.strip(" .,·")) and not _EXCEPTION.search(text):
        return NO_LIMIT_NOTE
    return note


def has_required_location(evidence: str, lines: list[str]) -> bool:
    """LLM 조건의 근거가 필수 역할 구절 하나 안에 들어가는 위치가 있는지 (D-056 4).

    우대·모호 구절이나 항목 제한 없음 문구('학년 무관') 안에만 있으면 False.
    """
    key = _compact(evidence)
    for info in read_lines(clean_lines(lines)):
        for seg in info.segs:
            span = _span(info, seg)
            if seg.role != "required" or key not in _compact(span):
                continue
            if any(key in _compact(m[0]) for m in UNRESTRICTED_ITEM.finditer(span)):
                continue
            return True
    return False


def clean_lines(lines) -> list[str]:
    return [line.strip() for line in lines if line.strip()]


def _dedupe(items: list[tuple[str, str | None]]) -> list[dict]:
    """번호·기호·항목 이름을 떼고, 같은 역할·표시 안에서만 같은 문구를 하나로 합친다 (D-056 3.5)."""
    out: dict[tuple, dict] = {}
    for evidence, note in items:
        text, _ = condition_text(evidence)
        if text is None:
            continue
        key = (_flag(note), re.sub(r"\s+", "", text))
        if key not in out:
            out[key] = {"evidence": text, "note": note}
    return list(out.values())


def tidy_unresolved(items: list[dict], lines: list[str]) -> tuple[list[dict], bool]:
    """미해석 조건을 정리한다: 번호·기호 떼기, 제목 줄 빼기, 같은 역할 안에서 같은 문구 하나로, 우대·항목 제한 없음 표시.

    우대 여부는 문구가 아니라 원문 위치로 정한다. 같은 문구가 필수와 우대 위치에 각각 나오면 둘 다 남긴다.
    돌려주는 bool은 제목 아래에서 읽은 항목이 없는 필수·혼합 제목이 있는지다(완전성을 막는 데 쓴다).
    """
    infos = read_lines(clean_lines(lines))
    prepared = [(item["evidence"], _locate_note(item["evidence"], infos, item["note"])) for item in items]
    return _dedupe(prepared), blocking_headings(infos)


# ---------- LLM 미해석 조건 거르기 (D-023) ----------

# 신청자 본인이 갖춰야 하는 조건을 말하는 낱말. 프로필로 판정하지 못하는 속성들
PERSONAL_HINT = re.compile(
    r"초과\s*학기|채플|표절|도용|수상\s*(?:이력|작)|평점|학점|성적|백분위|이수(?:자|한|했|\s*중)"
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


# 지원 자격이 아닌 안내 줄: 회사 소개, 복리후생·급여, 근무 조건, 모집 인원·부문, 담당 업무, 전형 절차·일정, 접수·제출, 문의, 유의사항 (D-056 3.7)
SENTENCE_END = re.compile(r"(?:습니다|합니다|니다|세요|[가-힣]요|[가-힣]다)[.!]?\s*$")
# 자격 문구가 끝나는 꼴: '…자', '…이상', '…소지', '…가능', '…한함', '…전공'. 구역 밖 목록 줄은 이런 꼴일 때만 단서로 본다(프로그램 소개 줄을 거른다)
QUALIFIER_END = re.compile(
    r"(?:자|분|생|이상|이하|미만|초과|소지|보유|경험|가능|필수|한함|한정|우대|제외|불가|해당|출신|거주|학과|전공|학위|학력|졸업|재학|대상)\)?\s*$"
)
INFO_LINE = re.compile(
    r"회사\s*소개|기업\s*소개|기관\s*소개|복리\s*후생|복지|급여|연봉|월급|근무\s*(?:지|지역|시간|형태|조건|요일)|고용\s*형태|채용\s*(?:구분|절차|분야|부문)"
    r"|모집\s*(?:인원|부문|분야|직무|기간)|담당\s*업무|주요\s*업무|업무\s*내용|전형|절차|일정|접수|면접|서류\s*평가|합격자|발표|문의|연락|유의|허위"
    r"|근로\s*(?:시간|기간)|선착순|정원|\d+\s*명|수도권|\d{4}\s*년|\d+\s*월|참고\s*사항"
    # 날짜·시각('2026.11.25.(수)', '(금) 16:00'), 상금·시상·참가비·숙박, 근로 시간 상한, 제출 서류·기재 안내
    r"|\d{4}\s*[.\-/]\s*\d{1,2}\s*[.\-/]|\d{1,2}\s*\.\s*\d{1,2}\s*\.?\s*\([월화수목금토일]\)|\d{1,2}:\d{2}"
    r"|상금|시상|[대금은동]상\s*\(|USD|참가비|숙박|식사|최대\s*\d+\s*(?:시간|H)|\d+\s*H(?![A-Za-z])"
    r"|이력서|자기\s*소개서|기재|양식"
)
# 학력·전공 낱말, 우대·자격 표지 (조건 단서)
EDU_WORD = re.compile(r"학위|전공|학과|학력|졸업|우대|(?:\S+\s+){2,}\S*대상|대상자|한함|한정|지원\s*가능|참여\s*가능")  # 짧은 제목 '근로 대상'은 단서가 아니다


@cache
def _major_names() -> tuple[str, ...]:
    return tuple(m["name_ko"] for m in _dictionary("majors"))


def has_clue(text: str) -> bool:
    """조건 단서: 자동 비교 필드(학년·재학 상태·학교·학과), 미해석 낱말, 신청자 본인 자격 낱말, 학력·전공 낱말, 우대·자격 표지, 제한 없음 문구."""
    return bool(
        PROFILE_HINT.search(text) or GRADE_RANGE.search(text) or GRADE_LIST.search(text) or GRADE_ONE.search(text)
        or UNIVERSITY.search(text) or UNRESOLVED.search(text) or APPLICANT_CONDITION.search(text) or SEE_ATTACHMENT.search(text)
        or PERSONAL_HINT.search(text) or EDU_WORD.search(text) or UNRESTRICTED.search(text)
        or any(name in text for name in _major_names())
    )


def is_notice(text: str, *, label_ok: bool = False) -> bool:
    """항목으로 만들지 않는 안내 줄인지. 기존 안내 패턴(서류·혜택·출결 등)은 신청자 조건 문구(APPLICANT_CONDITION)가 있어야만 면제되고,
    새 안내 패턴(근무 조건·모집 인원·일정 등)은 조건 단서가 있으면 면제된다 (D-056 3.7)."""
    preferred_mark = bool(_PREF_END.search(text.strip()) or any(_PREF_END.search(m[1].strip()) for m in _PAREN.finditer(text)))
    if (NOT_CONDITION.search(text) or NOT_ELIGIBILITY.search(text)) and not (APPLICANT_CONDITION.search(text) or UNRESTRICTED.search(text) or preferred_mark):
        return True
    return bool(INFO_LINE.search(text)) and not (has_clue(text) or label_ok)


def keep_item(text: str, *, label_ok: bool = False, section_ok: bool = False) -> bool:
    """이 줄을 미해석 항목으로 남길지 (D-056 3.7). 안내 줄은 조건 단서가 없으면 뺀다.

    조건 단서가 있으면 남긴다. 우대 항목 이름(label_ok)도 단서다. 독립 제목이 연 구역 안의 줄은 단서가 없어도 남긴다.
    """
    if is_notice(text, label_ok=label_ok):
        return False
    return has_clue(text) or label_ok or section_ok


def is_llm_condition(text: str, conditions: list[dict], unresolved: list[dict], lines: list[str] = ()) -> bool:
    """LLM이 낸 미해석 조건을 받을지. 신청자 본인 조건과 원문 우대 위치의 문구만 받고, 이미 보이는 문구는 다시 내지 않는다.

    LLM은 일정·혜택·제출 방법·팀 구성·주제·대상 설명도 조건으로 내곤 한다. 받는 쪽을 좁게 둔다.
    우대 사항은 지원 자격과 따로 묶여 확인 필요 수에 들지 않으니(D-015) 낱말과 관계없이 받는다.
    같은 문구라도 필수 위치와 우대 위치는 서로 다른 항목이라, 이미 보이는지는 같은 역할 안에서만 본다 (D-056).
    """
    if NOT_ELIGIBILITY.search(text) or (NOT_CONDITION.search(text) and not APPLICANT_CONDITION.search(text)):
        return False
    if is_notice(text):
        return False  # 안내 줄 (D-056 4)
    if OPEN_TO.search(text) and not LIMIT.search(text):
        return False
    key = _compact(text)
    note = _locate_note(text, read_lines(clean_lines(lines)), None) if lines else None
    if note == NO_LIMIT_NOTE:
        return False  # 항목별 제한 없음은 확인할 조건이 아니다
    if any(key in _compact(u["evidence"]) and _flag(u.get("note")) == note for u in unresolved):
        return False  # 규칙이 이미 그 줄을 확인 항목으로 냈다
    if note == PREFERRED_NOTE:
        return True
    if PERSONAL_HINT.search(text):
        return True
    # 이미 재학 상태·학년 조건으로 읽은 줄의 일부면 빼고, 따로 나온 학적 문구만 받는다
    return bool(PROFILE_HINT.search(text)) and not any(key in _compact(c["evidence"]) for c in conditions)


def is_admin_title(title: str, source_id: str) -> bool:
    if source_id in JOB_BOARDS:
        return bool(JOB_BOARD_ADMIN_TITLE.search(title))
    if ADMIN_TITLE.search(title):
        return True
    return bool(STAFF_TITLE.search(title)) and not STUDENT_TARGET_TITLE.search(title)


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
        admin = is_admin_title(title, raw["source_id"])
        category = "admin_notice" if admin else self._category(TAG_NOISE.sub(" ", title), TAG_NOISE.sub(" ", text))
        tag_source = title if category in TITLE_ONLY_TAG_CATEGORIES else text
        tag_text = "" if admin else TAG_NOISE.sub(" ", tag_source)  # 비학생 공지는 꼬리표 없음
        majors = {m["id"] for m in _dictionary("majors")}
        named = [m["id"] for m in _dictionary("majors") if m["name_ko"] in tag_text]
        fields = {
            "summary": None,  # 검증된 요약은 LLM 단계 이후
            "category": category,
            "interest_tags": _codes(INTEREST_RULES, tag_text, {i["id"] for i in _dictionary("interests")}),
            "related_majors": named + [c for c in _codes(MAJOR_RULES, tag_text, majors) if c not in named],
            "related_roles": _codes(ROLE_RULES, tag_text, {r["id"] for r in _dictionary("roles")}),
            **self._dates(lines, source),
            "eligibility": self._eligibility(raw, lines, source),
        }
        if admin:
            # 업체·교직원 대상 공지는 학생 지원 자격을 읽지 않는다: 학교 조건 등을 붙이지 않고, 업체 계약 공고는 마감도 잡지 않는다.
            # 읽지 않은 것이므로 완전·제한 없음으로 표시하지 않는다.
            fields["eligibility"] = {
                "conditions": [], "unresolved_conditions": [], "extraction_complete": False,
                "explicitly_unrestricted": False, "unrestricted_evidence": None,
            }
            if VENDOR_TITLE.search(title):
                fields.update(application_start=None, application_deadline=None, deadline_note=None)
        return fields

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
            if out["application_deadline"] is None and START_DEADLINE.search(line) and not is_activity_line(line) and not (end is None and FROM_START.search(line)):
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
                unresolved.append((evidence, None))
                return
            if not any(c["field"] == field for c in conditions):
                conditions.append({"field": field, "operator": operator, "value": value, "evidence": evidence, "validation_status": "validated"})

        def add_grades(values: list[int], line: str):
            if values == [1, 2, 3, 4]:
                return  # 전 학년을 나열한 것은 학년 조건이 아니다
            add("grade", "in", values, line)

        # 출처 학교 이름 바로 뒤에 재학생·졸업생이 오면 그 학교 조건 ('숭의여자대학교 재학생'). '○○대학교 학생 여러분' 같은 호칭은 아님
        school_name = next((u["name_ko"] for u in _dictionary("universities") if u["id"] == source.university_id), None)
        school_status = re.compile(re.escape(school_name) + r"\s*(?:재학생|졸업생|재학\s*중|학생\s*(?:또는|혹은|및)\s*졸업)") if school_name else None

        unrestricted_line = None
        infos = read_lines(lines)
        for info in infos:
            if info.kind != "body":
                continue
            for seg in info.segs:
                if seg.role == "preferred":
                    # 우대는 조건을 만들지 않고 보존만 한다. 우대 표지·우대 항목 이름·우대 전용 구역 안의 줄만 항목으로 남긴다 (D-056 3.7)
                    if keep_item(seg.text, label_ok=info.label_ctx == "preferred", section_ok=info.sect == "preferred"):
                        unresolved.append((seg.text, PREFERRED_NOTE))
                    continue
                if seg.role == "ambiguous":
                    # 역할을 정할 수 없는 문구도 조건을 만들지 않고, 조건 단서가 있을 때만 직접 확인으로 남긴다
                    if keep_item(seg.text):
                        unresolved.append((seg.text, None))
                    continue
                line = seg.text
                matched = False
                if m := GRADE_RANGE.search(line):
                    lo, hi = sorted((int(m[1]), int(m[2])))
                    add_grades(list(range(lo, hi + 1)), line)
                    matched = True
                elif m := GRADE_LIST.search(line):
                    add_grades(sorted({int(d) for d in re.findall(r"[1-4]", m[1])}), line)
                    matched = True
                elif m := GRADE_ONE.search(line):
                    add("grade", "eq", int(m[1]), line)
                    matched = True

                statuses = [s for s, p in (("enrolled", r"재학생|재\s*[·ㆍ･,/]\s*휴학생"), ("on_leave", r"휴학생"), ("graduated", r"졸업생|졸업자")) if re.search(p, line)]
                if "enrolled" not in statuses and STUDENT_OR_GRADUATE.search(line):
                    statuses.insert(0, "enrolled")  # '학생 또는 졸업생'은 졸업생만이 아니다
                if HIGH_SCHOOL_OR_MORE.search(line) and not NOT_CONDITION.search(line):
                    add("enrollment_status", "in", ["enrolled", "on_leave", "graduated"], line)
                    matched = True
                elif statuses and OTHER_STATUS.search(line):
                    unresolved.append((line, None))  # 복학생·입학예정자 등은 프로필 재학 상태로 판정할 수 없다
                    matched = True
                elif statuses:
                    matched = True
                    add("enrollment_status", "eq" if len(statuses) == 1 else "in", statuses[0] if len(statuses) == 1 else statuses, line)

                if source.university_id and (UNIVERSITY.search(line) or (school_status and school_status.search(line))):
                    add("university_id", "eq", source.university_id, line)
                    matched = True

                named = [m["id"] for m in majors if m["name_ko"] in line and re.search(re.escape(m["name_ko"]) + r"\s*(?:재학생|학생|대상|소속)", line)]
                if named:
                    add("major_id", "eq" if len(named) == 1 else "in", named[0] if len(named) == 1 else named, line)
                    matched = True

                def required_unresolved(piece: str, broad: bool = True) -> bool:
                    # 제한 없음 문구가 있는 줄은 '무관' 등으로 면제하지 않는다 ('학년 무관, 소득분위 3분위 이하')
                    exempt = NOT_CONDITION.search(piece) and not UNRESTRICTED.search(piece)
                    if (UNRESOLVED.search(piece) and not exempt) or SEE_ATTACHMENT.search(piece) or APPLICANT_CONDITION.search(piece):
                        return True
                    # 자동으로 읽은 줄이 아니면: 조건 단서가 있는 줄, 필수 구역 안의 줄(안내 줄 제외) (D-056 3.7)
                    # 문장(안내문)은 항목이 아니다. 필수 구역 밖에서는 목록 기호·항목 이름이 붙은 자격 꼴 줄만 본다
                    if not broad or matched or SENTENCE_END.search(piece):
                        return False
                    if OPEN_TO.search(piece) and not LIMIT.search(piece):
                        return False  # 대상을 넓히는 말('주·야간 학생 모두 지원 가능')은 확인할 자격이 아니다 (LLM 경로와 같은 기준)
                    if info.sect == "required":
                        return keep_item(piece, section_ok=True)
                    return info.listy and bool(QUALIFIER_END.search(piece)) and keep_item(piece)

                item = None if UNRESTRICTED_ALL.search(line) else UNRESTRICTED_ITEM.search(line)
                if UNRESTRICTED_ALL.search(line):
                    if unrestricted_line is None:
                        unrestricted_line = line  # 전체 제한 없음만 명시적 제한 없음의 근거다
                    if required_unresolved(line, broad=False):  # '누구나 …' 줄 자체는 단서가 아니다
                        unresolved.append((line, None))
                elif item:
                    # 그 항목에만 제한이 없다. 나머지 자격이 열렸다는 근거가 아니다. 예외가 붙으면 구절 전체를 직접 확인으로 둔다.
                    # 같은 줄의 다른 구절은 따로 본다: 줄 전체를 하나로 묶지 않는다
                    end = item.end()
                    if ex := _EXCEPTION.match(line, end):
                        end = ex.end()
                        unresolved.append((line[item.start():end].strip(), None))
                    else:
                        unresolved.append((item[0], NO_LIMIT_NOTE))
                    for piece in (line[:item.start()], line[end:]):
                        piece = piece.strip(_TRIM)
                        if piece and required_unresolved(piece):
                            unresolved.append((piece, None))
                elif required_unresolved(line):
                    unresolved.append((line, None))

        unresolved = _dedupe(unresolved)
        # 우대·항목 제한 없음은 판정·완전성·명시적 제한 없음에서 뺀다 (D-056)
        real = [u for u in unresolved if u["note"] not in FLAG_NOTES]
        # 제한 없음 문구가 있어도 조건이나 미해석 조건이 남으면 '제한 없음'으로 보지 않는다 (SPEC §5)
        explicit = unrestricted_line is not None and not conditions and not real
        complete = (
            (bool(conditions) or explicit)
            and not real
            and not blocking_headings(infos)  # 필수·혼합 제목 아래에서 읽은 항목이 없으면 그 아래 조건을 놓쳤을 수 있다
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
