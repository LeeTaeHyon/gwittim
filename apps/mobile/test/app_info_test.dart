import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/main.dart';
import 'package:gwittim/ui/app_info.dart';
import 'package:gwittim/ui/briefing_data.dart';
import 'package:gwittim/ui/profile_screen.dart';

void main() {
  test('보이는 버전은 pubspec.yaml의 version과 같다', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*([^\s+]+)', multiLine: true).firstMatch(pubspec)!.group(1);
    expect(appVersion, version);
  });

  testWidgets('Pretendard 라이선스가 오픈소스 라이선스 목록에 들어간다', (tester) async {
    registerAppLicenses();
    final entries = await tester.runAsync(() => LicenseRegistry.licenses.toList());
    final pretendard = entries!.where((e) => e.packages.contains('Pretendard')).toList();
    expect(pretendard, hasLength(1));
    final text = pretendard.single.paragraphs.map((p) => p.text).join('\n');
    expect(text, contains('SIL Open Font License'));
    expect(text, contains('Kil Hyung-jin'));
    expect(text, isNot(contains('\r')));
  });

  testWidgets('설정 > 앱 정보: 버전이 보이고, 오픈소스 라이선스를 누르면 라이선스 화면이 열린다', (tester) async {
    final repo = SampleNoticeRepository(personalized: false);
    await tester.runAsync(repo.preload);
    await tester.pumpWidget(
      GwittimApp(
        repository: repo,
        openUrl: (_) async => true,
        today: DateTime(2026, 10, 17),
        briefingStore: MemoryBriefingStore(alwaysShown: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('내 정보'));
    await tester.pumpAndSettle();

    final list = find.descendant(of: find.byType(ProfileScreen), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('오픈소스 라이선스'), 200, scrollable: list);
    await tester.pumpAndSettle();
    expect(find.text('버전'), findsOneWidget);
    expect(find.text(appVersion), findsOneWidget);

    await tester.tap(find.text('오픈소스 라이선스'));
    // 라이선스 화면은 목록을 모으는 동안 회전 표시가 돌아서 pumpAndSettle이 끝나지 않는다.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('귀띔'), findsWidgets);
  });
}
