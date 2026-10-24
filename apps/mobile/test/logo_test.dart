import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/ui/components.dart';
import 'package:gwittim/ui/logo.dart';
import 'package:gwittim/ui/theme.dart';

void main() {
  group('로고 도형 (D-011)', () {
    test('docs/brand/logo.svg와 같은 path·배치', () {
      final svg = File('../../docs/brand/logo.svg').readAsStringSync();
      final paths = RegExp(r'<path [^>]*\bd="([^"]+)"').allMatches(svg).map((m) => m[1]).toList();
      expect(paths, [logoBubbleData, logoGlyphData]);
      expect(svg, contains('viewBox="0 0 400 250"'));
      expect(svg, contains('transform="translate(72 40) scale(1.15)"'));
    });

    test('말풍선: 둥근 모서리와 왼쪽 아래 꼬리', () {
      final bubble = svgPath(logoBubbleData);
      expect(bubble.getBounds(), const Rect.fromLTRB(0, 0, 400, 250));
      expect(bubble.contains(const Offset(3, 3)), isFalse); // 모서리는 바깥으로 둥글다
      expect(bubble.contains(const Offset(56, 3)), isTrue);
      expect(bubble.contains(const Offset(4, 242)), isTrue); // 꼬리
      expect(bubble.contains(const Offset(396, 240)), isFalse);
    });

    test('글자: 띔의 받침 ㅁ은 속이 빈 작은 말풍선', () {
      final glyph = svgPath(logoGlyphData);
      expect(glyph.getBounds(), const Rect.fromLTRB(0, 0, 222, 128));
      expect(glyph.contains(const Offset(170, 99)), isFalse); // 속
      expect(glyph.contains(const Offset(128, 99)), isTrue); // 왼쪽 획
      expect(glyph.contains(const Offset(123, 79)), isFalse); // 둥근 모서리 바깥
      expect(glyph.contains(const Offset(123, 126)), isTrue); // 꼬리
    });

    test('모르는 명령은 거부', () {
      expect(() => svgPath('m0 0h10z'), throwsFormatException);
    });
  });

  for (final brightness in Brightness.values) {
    testWidgets('배지 크기와 읽기 이름 (${brightness.name})', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: gwittimTheme(brightness),
          home: const Scaffold(body: Column(children: [GwBadge(), GwBadge(small: true)])),
        ),
      );
      final badges = find.byType(GwLogo);
      expect(tester.getSize(badges.first), const Size(44.8, 28));
      expect(tester.getSize(badges.last), const Size(35.2, 22));
      expect(find.bySemanticsLabel('귀띔'), findsNWidgets(2));
    });
  }
}
