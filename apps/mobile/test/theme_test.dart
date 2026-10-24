import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/main.dart';
import 'package:gwittim/ui/briefing_data.dart';
import 'package:gwittim/ui/home_screen.dart';
import 'package:gwittim/ui/profile_screen.dart';
import 'package:gwittim/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BrokenThemeStore implements ThemeStore {
  @override
  Future<ThemeMode> read() => Future.error(Exception('storage'));

  @override
  Future<void> write(ThemeMode mode) => Future.error(Exception('storage'));
}

/// WCAG 대비
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// 반투명 색을 바탕 위에 얹은 색
Color over(Color top, Color bottom) => Color.alphaBlend(top, bottom);

void main() {
  group('화면 설정 저장 (기기)', () {
    test('저장된 값이 없으면 시스템 설정', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await PrefsThemeStore().read(), ThemeMode.system);
    });

    test('고른 값을 저장하고 다시 읽는다', () async {
      SharedPreferences.setMockInitialValues({});
      await PrefsThemeStore().write(ThemeMode.dark);
      expect((await SharedPreferences.getInstance()).getString(PrefsThemeStore.key), 'dark');
      expect(await PrefsThemeStore().read(), ThemeMode.dark);
    });

    test('알 수 없는 값은 시스템 설정', () async {
      SharedPreferences.setMockInitialValues({PrefsThemeStore.key: 'purple'});
      expect(await PrefsThemeStore().read(), ThemeMode.system);
    });

    test('앱 시작 때 저장된 값을 읽고, 바꾸면 저장한다', () async {
      SharedPreferences.setMockInitialValues({PrefsThemeStore.key: 'light'});
      final controller = await ThemeController.load(PrefsThemeStore());
      expect(controller.value, ThemeMode.light);
      await controller.select(ThemeMode.dark);
      expect(controller.value, ThemeMode.dark);
      expect(await PrefsThemeStore().read(), ThemeMode.dark);
    });

    test('기기 저장소를 못 쓰면 시스템 설정으로 시작하고, 바꾼 값은 이번 실행에만 적용', () async {
      final controller = await ThemeController.load(BrokenThemeStore());
      expect(controller.value, ThemeMode.system);
      await controller.select(ThemeMode.dark);
      expect(controller.value, ThemeMode.dark);
    });
  });

  group('색 토큰 (D-010)', () {
    for (final (name, c) in [('라이트', GwColors.light), ('다크', GwColors.dark)]) {
      test('$name: 글자는 카드·바탕 대비 4.5:1 이상', () {
        for (final text in [c.ink, c.body, c.sub, c.muted, c.accent, c.urgent, c.check]) {
          expect(contrast(text, c.card), greaterThanOrEqualTo(4.5), reason: '$text on card');
          expect(contrast(text, c.bg), greaterThanOrEqualTo(4.5), reason: '$text on bg');
        }
        expect(contrast(c.onChip, c.chip), greaterThanOrEqualTo(4.5));
        expect(contrast(c.sub, c.neutral), greaterThanOrEqualTo(4.5));
        expect(contrast(c.urgent, c.urgentSoft), greaterThanOrEqualTo(4.5));
        expect(contrast(c.check, c.checkSoft), greaterThanOrEqualTo(4.5));
        expect(contrast(c.onCta, c.cta), greaterThanOrEqualTo(4.5));
        expect(contrast(c.onPoint, c.point), greaterThanOrEqualTo(4.5));
        expect(contrast(c.onUrgentFill, c.urgentFill), greaterThanOrEqualTo(4.5));
        expect(contrast(c.onToast, c.toast), greaterThanOrEqualTo(4.5));
        expect(contrast(c.limeInk, c.lime), greaterThanOrEqualTo(4.5));
        expect(contrast(c.onTab, c.tab), greaterThanOrEqualTo(4.5), reason: '탭 막대 글자');
        expect(contrast(c.ink, over(c.marker, c.card)), greaterThanOrEqualTo(4.5), reason: '형광펜 위 글자');
        expect(contrast(c.body, c.summary), greaterThanOrEqualTo(4.5));
        expect(contrast(c.loginInk, c.loginBg), greaterThanOrEqualTo(4.5));
        expect(contrast(c.loginSub, c.loginBg), greaterThanOrEqualTo(4.5));
        expect(contrast(c.ink, c.loginCard), greaterThanOrEqualTo(4.5));
      });
    }

    test('다크에서 라임은 면으로만: 글자색 토큰에 라임이 없다', () {
      const c = GwColors.dark;
      for (final text in [c.ink, c.body, c.sub, c.muted, c.accent, c.onChip, c.urgent, c.check, c.onCta, c.onPoint]) {
        expect(text, isNot(c.lime));
      }
      expect(c.cta, c.lime);
      expect(c.point, c.lime);
      expect(c.marker.a, lessThan(1)); // 형광펜은 투명하게
    });

    test('테마 두 벌이 토큰을 담는다', () {
      expect(gwittimTheme().extension<GwColors>(), GwColors.light);
      expect(gwittimTheme(Brightness.dark).extension<GwColors>(), GwColors.dark);
      expect(gwittimTheme(Brightness.dark).scaffoldBackgroundColor, const Color(0xFF0F1222));
      expect(gwittimTheme().colorScheme.brightness, Brightness.light);
    });
  });

  testWidgets('저장된 다크로 시작하고, 프로필 화면 설정에서 라이트로 바꾸면 저장된다', (tester) async {
    final repo = SampleNoticeRepository();
    await tester.runAsync(repo.preload);
    final store = MemoryThemeStore(ThemeMode.dark);
    final controller = await ThemeController.load(store);
    await tester.pumpWidget(
      GwittimApp(
        repository: repo,
        openUrl: (_) async => true,
        today: DateTime(2026, 10, 17),
        briefingStore: MemoryBriefingStore(alwaysShown: true),
        themeController: controller,
      ),
    );
    await tester.pumpAndSettle();

    final home = tester.element(find.byType(HomeScreen));
    expect(Theme.of(home).brightness, Brightness.dark);
    expect(home.gw, GwColors.dark);

    await tester.tap(find.text('프로필'));
    await tester.pumpAndSettle();
    final profileList = find.descendant(of: find.byType(ProfileScreen), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('라이트'), 300, scrollable: profileList);
    await tester.pumpAndSettle();
    await tester.tap(find.text('라이트'));
    await tester.pumpAndSettle();

    expect(controller.value, ThemeMode.light);
    expect(await store.read(), ThemeMode.light);
    expect(Theme.of(tester.element(find.byType(ProfileScreen))).brightness, Brightness.light);
    expect(Theme.of(tester.element(find.byType(HomeScreen, skipOffstage: false))).brightness, Brightness.light);

    await tester.tap(find.text('시스템 설정'));
    await tester.pumpAndSettle();
    expect(await store.read(), ThemeMode.system);
  });
}
