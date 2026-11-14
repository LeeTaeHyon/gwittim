// 기기 안 알림톡 종류 판정·가림이 서버 파서와 같은 결과를 내는지 (D-034).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/classifier/kakao_filter.dart';

// 파서(backend/collectors/mjc_kakao/parser.py)로 만든 골든. 파이썬 테스트도 같은 파일을 검사한다.
const _golden = '../../backend/collectors/mjc_kakao/tests/filter_golden.json';

void main() {
  final golden = jsonDecode(File(_golden).readAsStringSync()) as Map<String, dynamic>;
  final cases = (golden['cases'] as List).cast<Map<String, dynamic>>();

  test('받는 사람 이름 찾기가 파서와 같다', () {
    final cleaned = [for (final c in cases) cleanBody(c['raw'] as String)];
    expect(detectNames(cleaned).toList()..sort(), (golden['names'] as List).cast<String>());
  });

  final names = (golden['names'] as List).cast<String>().toSet();
  for (final (i, c) in cases.indexed) {
    test('골든 $i: ${c['kind']} ${(c['title'] as String).runes.take(20).map(String.fromCharCode).join()}', () {
      final clean = cleanBody(c['raw'] as String);
      expect(clean, c['clean'], reason: '본문 정리');
      expect(kakaoKind(clean, names), c['kind'], reason: '종류');
      final masked = maskPersonal(clean, names);
      expect(masked, c['masked'], reason: '가림');
      expect(kakaoTitle(masked, c['room'] as String), c['title'], reason: '제목');
    });
  }

  test('줄 바꿈·공백은 파이썬 규칙을 따른다', () {
    expect(cleanBody('a\r\nb c\u0085d'), 'a\nb\nc\nd');
    expect(cleanBody('　앞뒤 공백　'), '앞뒤 공백');
    expect(cleanBody('﻿남김'), '﻿남김'); // 파이썬 strip은 BOM을 지우지 않는다
    expect(cleanBody('a\n\n\n\nb'), 'a\n\nb');
    expect(cleanBody(''), '');
  });
}
