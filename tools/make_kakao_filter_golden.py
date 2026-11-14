"""알림톡 종류 판정·개인정보 가림 골든을 파서(backend/collectors/mjc_kakao/parser.py)로 만든다 (D-034).

기기 안 이식(apps/mobile/lib/classifier/kakao_filter.dart)이 파서와 같은 결과를 내는지 양쪽 테스트가 이 파일로 검사한다.
  backend/collectors/mjc_kakao/tests/test_filter_golden.py  파일이 지금 파서 결과와 같은가
  apps/mobile/test/kakao_filter_test.dart                    Dart 이식이 파일과 같은가
입력은 모두 직접 쓴 합성 문장이다. 이름·학번·전화번호도 지어낸 값이다.

실행: uv run python tools/make_kakao_filter_golden.py   (파서 규칙을 바꾸면 다시 만든다)
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))  # python tools/x.py 로 돌릴 때 필요

from backend.collectors.mjc_kakao.parser import (  # noqa: E402
    classify, clean_body, detect_names, mask, title_of,
)

OUT = ROOT / "backend/collectors/mjc_kakao/tests/filter_golden.json"
ROOM = "명지전문대학 교수학습지원"

# (방, 원문). 원문은 내보내기 한 메시지의 줄을 이은 것과 같은 모양이다.
CASES: list[tuple[str, str]] = [
    # 공통 공지
    (ROOM, "[명지전문대학 교수학습센터]\n안녕하세요. 명지전문대학 교수학습센터입니다.\n\n"
           "2026학년도 2학기 학습컨설팅 참여자를 모집합니다.\n- 신청기간: 9월 1일 ~ 9월 12일\n- 문의: 02-300-0000"),
    ("명지전문대학 글로벌교육센터", "글로벌교육센터 2026-하계 글로벌 어학아카데미 안내\n영어(TOEIC) 공인시험 맞춤 강의\n모집기간: ~2026.06.12.까지"),
    ("명지전문대학 공지사항", "즐거운 개강입니다!\n2학기 수강신청 정정 기간을 안내드립니다.\n기간: 9월 2일(화) ~ 9월 5일(금)"),
    ("명지전문대학 스마트케어", "저는 명지전문대학 SMART CARE 시스템의 어드바이징 봇 'SMART CARE 봇'입니다.\n"
                             "핵심역량 진단검사를 실시해 주세요. 기간: 10월 31일까지"),
    ("명지전문대학 상담센터", "[명지전문대학 상담센터]\n안녕하세요 홍길동님!\n심리특강 '감정이 널뛰는 나'에 초대합니다.\n일시: 11월 24일(월) 14시"),
    # 개인 알림: 학번 + 학생, 이름 + 결과·완료
    ("명지전문대학 원격교육지원센터", "2026123456 학생, 원격강좌 시험 응시 환경 점검 결과를 알려드립니다. 다음 주 시험 전에 꼭 확인하세요."),
    (ROOM, "홍길동님의 학습역량 진단검사 결과: 우수\n자세한 내용은 스마트케어에서 확인하세요."),
    (ROOM, "홍길동님 버디업 멘토링 신청이 완료되었습니다. 첫 모임 일정은 따로 안내합니다."),
    (ROOM, "홍길동님 안녕하세요. 2학기 학습컨설팅 프로그램을 안내드립니다. 모집기간 9월 12일까지 많은 참여 바랍니다."),
    # 수강 과목 알림
    ("명지전문대학 원격교육지원센터", "[인성채플 104반] 11주차 가정폭력예방교육 강의를 아직 수강하지 않았습니다.\n기간 내에 수강하여 주십시요."),
    ("명지전문대학 원격교육지원센터", "정보능력 801반 공지사항을 다음과 같이 알려드립니다. 중간고사는 온라인으로 진행합니다."),
    ("명지전문대학 원격교육지원센터", "과제 미제출 학생은 이번 주 금요일까지 제출 바랍니다. 기한이 지나면 받지 않습니다."),
    # 참여자 대상 운영 안내 / 모집 중이면 공통 공지
    (ROOM, "명지튜터링에 참여하고 계신 튜터/튜티 여러분, 3주차 학습보고서를 제출해 주세요. 제출 현황은 홈페이지에 있습니다."),
    (ROOM, "버디업 멘토링 프로그램 운영이 완료됨에 따라 참여 학생 대상 만족도 조사를 진행합니다. 링크로 응답해 주세요."),
    (ROOM, "참여 학생 여러분 감사합니다. 버디업 멘토링 추가 모집을 진행합니다. 신청기간 9월 25일까지 빠른 신청 바랍니다."),
    # 잡음: 자동응답, 짧은 글, 빈 템플릿
    ("명지전문대학 공지사항", "관리자가 없을때 대신 답변하는 채널 AI에요.\n안녕하세요, 채널 AI 매니저예요. 무엇을 도와드릴까요?"),
    ("명지전문대학 공지사항", "[안내]\n안녕하세요\n문의 02-300-0000"),
    ("명지전문대학 공지사항", "#{학과명} #{이름}님\n\n\n\n#{안내문구}\n상세 내용은 홈페이지를 확인하세요. 감사합니다 여러분."),
    # 가림: 학번·휴대폰·교수 이름·받는 사람 이름, 전각 숫자
    ("명지전문대학 원격교육지원센터", "[교양 정보능력 수업]\n담당교수: 김철수\n질문은 김철수 교수님께 메일로 보내 주세요.\n"
                                    "조교 연락처 010-1234-5678, 예시 학번 2026000001_홍길동 형식으로 제출."),
    ("명지전문대학 원격교육지원센터", "안녕하세요 이영희 교수입니다.\n전각 학번 ２０２６１２３４５６ 학생도 같은 규칙입니다. 이번 주 퀴즈를 꼭 응시하세요."),
    (ROOM, "이영희님 다음 주 상담 일정 확정 안내입니다. 일정 변경은 상담센터로 연락 바랍니다. 이영희님 감사합니다."),
    # 공백·줄 바꿈 차이 (전각 공백, \r\n, 줄 끝 공백, 줄 구분자, 이모지)
    ("명지전문대학 글로벌교육센터", "📢　글로벌 외국어회화 안내　\r\n원어민 1:1 수준별 회화 프로그램   \r\n모집기간 : ~ 2026.03.28.까지\r\n"),
    ("명지전문대학 공지사항", "﻿학생복지팀 안내 학생식당 식비 지원사업을 운영합니다.\x85지원기간: 1학기 및 2학기\u000b문의 학생복지팀"),
    ("명지전문대학 공지사항", "   \n\n명지전문대학 공지사항\n공지사항\n\n<이름>님\n2026학년도 총학생회 선거 투표 안내\n어느 투표소에서든 투표 가능합니다."),
    ("명지전문대학 상담센터", "⭐상담센터 집중휴무제 기간 안내⭐\n" + "상담이 없음을 알려드립니다. " * 12),
]


def build() -> dict:
    cleaned = [clean_body({"lines": raw.splitlines()}) for _, raw in CASES]
    names = detect_names(cleaned)
    cases = []
    for (room, raw), text in zip(CASES, cleaned):
        masked = mask(text, sorted(names))
        cases.append({
            "room": room, "raw": raw, "clean": text, "kind": classify(text, names),
            "masked": masked, "title": title_of(masked, room),
        })
    return {"names": sorted(names), "cases": cases}


def main() -> int:
    OUT.write_text(json.dumps(build(), ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{len(CASES)}건 → {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
