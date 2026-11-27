import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/share/ocr_cleanup.dart';

// 실기기 캡처 1장의 문제(상태 표시줄 시각이 제목, 카톡 화면 요소 혼입, 제목 두 줄 쪼개짐)를 합성 줄로 재현한다.
OcrLine _l(String t, double top, {double left = 60, double right = 900}) =>
    OcrLine(t, left: left, top: top, right: right, bottom: top + 48);

void main() {
  realCaptureTests();
  emojiAndSenderTests();
  final lines = [
    _l('8:54 ALIR)', 40, right: 300),
    _l('← 명지전문대학 공지사항', 150, right: 700),
    _l('Ch+ 채널 추가', 280, right: 500),
    _l('알림톡 차단', 340, right: 460),
    _l('2026학년도 동계방학 어학아카데미', 700, right: 1000),
    _l('안내', 760, right: 150),
    _l('- 신청 기간: 12월 18일(목)까지', 900, right: 800),
    _l('- 대상: 재학생 누구나 신청 가능하며 선착순으로', 970, right: 1000),
    _l('마감합니다', 1030, right: 280),
    _l('- 문의: 어학교육원', 1130, right: 600),
    _l('채널 홈 바로가기', 2100, right: 700),
    _l('.l 88', 2160, right: 200),
    _l('메시지를 입력하세요', 2300, right: 800),
  ];

  test('제목이 두 줄로 쪼개져도 합치고, 카톡 화면 요소는 뺀다', () {
    final text = cleanOcrLines(lines, imageHeight: 2400);
    expect(text.split('\n').first, '2026학년도 동계방학 어학아카데미 안내');
    expect(text, contains('- 신청 기간: 12월 18일(목)까지'));
    for (final noise in ['8:54', '채널 추가', '알림톡 차단', '바로가기', '.l 88', '공지사항']) {
      expect(text, isNot(contains(noise)));
    }
  });

  test('항목은 합치지 않고, 오른쪽 끝까지 찬 줄의 이어진 줄은 합친다', () {
    final text = cleanOcrLines(lines, imageHeight: 2400).split('\n');
    expect(text, contains('- 대상: 재학생 누구나 신청 가능하며 선착순으로 마감합니다'));
    expect(text, contains('- 문의: 어학교육원'));
  });

  test('이미지 높이를 모르면 위치로 거르지 않고 문구·패턴으로만 거른다', () {
    final text = cleanOcrLines(lines);
    expect(text.split('\n').first, '2026학년도 동계방학 어학아카데미 안내');
    expect(text, isNot(contains('8:54')));
  });

  test('빈 입력은 빈 글', () {
    expect(cleanOcrLines([]), '');
    expect(cleanOcrLines([_l('8:54', 10)], imageHeight: 2400), '');
  });
}

// 실제 카톡 캡처 1장(1440x3120)의 ML Kit 줄·단어·글자 좌표를 그대로 고정한 자료(학교 공지 글자만, 연락처는 가짜 번호로 바꿈).
List<OcrLine> _fixtureLines(Map<String, dynamic> json) => [
  for (final l in json['lines'] as List)
    OcrLine(
      l['t'] as String,
      left: (l['l'] as num).toDouble(),
      top: (l['tp'] as num).toDouble(),
      right: (l['r'] as num).toDouble(),
      bottom: (l['b'] as num).toDouble(),
      words: [
        for (final (i, w) in (l['w'] as List).indexed)
          OcrWord(
            w['t'] as String,
            left: (w['l'] as num).toDouble(),
            top: (l['tp'] as num).toDouble(),
            right: (w['r'] as num).toDouble(),
            bottom: (l['b'] as num).toDouble(),
            confidence: (w['c'] as num?)?.toDouble(),
            symbols: [
              for (final y in (l['sy'] as List)[i] as List)
                OcrWord(
                  y['t'] as String,
                  left: (y['l'] as num).toDouble(),
                  top: (l['tp'] as num).toDouble(),
                  right: (y['r'] as num).toDouble(),
                  bottom: (l['b'] as num).toDouble(),
                  confidence: (y['c'] as num?)?.toDouble(),
                ),
            ],
          ),
      ],
    ),
];

void realCaptureTests() {
  final json =
      jsonDecode(File('test/data/ocr_kakao_capture_01.json').readAsStringSync())
          as Map<String, dynamic>;
  final lines = _fixtureLines(json);
  final height = (json['image_height'] as num).toDouble();

  group('실제 카톡 캡처 회귀', () {
    final text = cleanOcrLines(lines, imageHeight: height);
    final out = text.split('\n');

    test('첫 줄은 제목이고 가려진 보낸 이름 줄은 없다', () {
      expect(out.first, '2026학년도 동계방학 어학아카데미 안내');
      expect(text, isNot(contains('명시선문내악')));
    });

    test('채널 화면 문구·상태 표시줄·하단 메뉴는 없다', () {
      for (final noise in ['8:54', '공지사항', '채널 추가', '알림톡 차단', '채널 홈', '바로가', 'l 88']) {
        expect(text, isNot(contains(noise)), reason: noise);
      }
    });

    test('항목 줄은 이어 붙지 않는다', () {
      expect(out, contains('참가비: 5만 원 입금까지 완료해야 신청 완료'));
      expect(out.any((l) => l.startsWith('운영기관:')), isTrue);
      expect(out, contains('교육방법: 실시간 비대면 수업'));
    });

    test('본문 줄은 빠지지 않는다', () {
      for (final must in [
        '안녕하세요 글로벌교육팀입니다.',
        '12월 18일(금)까지 선착순 모집',
        '참가비 5만 원 전액 환급 (이수조건 충족 시)',
        '이수 조건',
        '지금 신청하기',
        '교육기간: 총 36시간 (3시간 x 12회)',
        '문의 : 02-000-0000',
      ]) {
        expect(out, contains(must), reason: must);
      }
      // 인식 38줄 - 채널 화면·상태 표시줄·보낸 이름 7줄 - 이어 붙인 2곳(제목 두 줄, '안내를 드립니다') = 29줄
      expect(out.length, 29);
    });
  });
}

void emojiAndSenderTests() {
  OcrWord sym(String t, double l, double r, double c) =>
      OcrWord(t, left: l, top: 0, right: r, bottom: 40, confidence: c);

  OcrLine withSymbols(String text, List<OcrWord> symbols, {double top = 500}) =>
      OcrLine(
        text,
        left: symbols.first.left,
        top: top,
        right: symbols.last.right,
        bottom: top + 40,
        words: [
          OcrWord(
            text.replaceAll(' ', ''),
            left: symbols.first.left,
            top: top,
            right: symbols.last.right,
            bottom: top + 40,
            symbols: symbols,
          ),
        ],
      );

  group('이모지 자리 글자', () {
    test('줄 맨 앞에서 간격이 벌어진 낮은 신뢰도 1글자 조각은 지운다', () {
      final l = withSymbols('수지금', [
        sym('수', 221, 275, 0.2),
        sym('지', 292, 327, 0.9),
        sym('금', 327, 362, 0.9),
      ]);
      final out = cleanOcrLines([l, _lineAt('본문입니다 안내 12월 3일까지', 600)]);
      expect(out.split('\n').first, '지금');
    });

    test('간격이 붙은 정상 단어의 첫 글자·신뢰도 높은 글자·숫자는 지우지 않는다', () {
      final attached = withSymbols('지금', [
        sym('지', 210, 240, 0.2),
        sym('금', 242, 272, 0.9),
        sym('요', 272, 300, 0.9),
      ]);
      final confident = withSymbols('수지금', [
        sym('수', 221, 275, 0.9),
        sym('지', 292, 327, 0.9),
        sym('금', 327, 362, 0.9),
      ]);
      final digit = withSymbols('5만원', [
        sym('5', 221, 245, 0.2),
        sym('만', 262, 297, 0.9),
        sym('원', 297, 332, 0.9),
      ]);
      expect(cleanOcrLines([attached]), '지금');
      expect(cleanOcrLines([confident]), '수지금');
      expect(cleanOcrLines([digit]), '5만원');
    });
  });

  group('가려진 보낸 이름 줄', () {
    final bar = OcrLine('← 명지전문대학 공지사항', left: 53, top: 196, right: 639, bottom: 251);
    OcrLine content(String t, double top) => _lineAt(t, top);

    test('채널 이름과 자모가 비슷한 첫 줄은 지운다', () {
      final out = cleanOcrLines([
        bar,
        content('명시선문내악', 478),
        content('2026학년도 동계방학 어학아카데미 안내', 528),
      ], imageHeight: 3120);
      expect(out, '2026학년도 동계방학 어학아카데미 안내');
    });

    test('공백이 있거나 숫자가 있거나 이름과 다른 첫 줄은 지우지 않는다', () {
      for (final title in ['합격자 안내입니다', '전문대학 안내', '장학금신청안내', '2026학년도안내']) {
        final out = cleanOcrLines([bar, content(title, 478), content('신청 기간: 12월 3일까지', 540)], imageHeight: 3120);
        expect(out.split('\n').first, title, reason: title);
      }
    });

    test('채널 이름 줄이 없으면 아무것도 지우지 않는다', () {
      final out = cleanOcrLines([content('명시선문내악', 478), content('신청 기간: 12월 3일까지', 540)], imageHeight: 3120);
      expect(out.split('\n').first, '명시선문내악');
    });

    test('자모 비슷함', () {
      expect(jamoSimilarity('명시선문내악', '명지전문대학'), greaterThan(0.6));
      expect(jamoSimilarity('합격자안내', '명지전문대학'), lessThan(0.4));
    });
  });
}

OcrLine _lineAt(String t, double top) =>
    OcrLine(t, left: 289, top: top, right: 289 + t.length * 30.0, bottom: top + 40);
