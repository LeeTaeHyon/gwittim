import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/main.dart';
import 'package:gwittim/ui/briefing_data.dart';
import 'package:gwittim/ui/components.dart';
import 'package:gwittim/ui/home_screen.dart';
import 'package:gwittim/ui/profile_screen.dart';
import 'package:gwittim/ui/theme.dart';

const tabs = <GwTab>[
  (icon: Icons.home_outlined, activeIcon: Icons.home_rounded, label: '홈'),
  (icon: Icons.bookmark_border_rounded, activeIcon: Icons.bookmark_rounded, label: '저장'),
  (icon: Icons.person_outline_rounded, activeIcon: Icons.person_rounded, label: '프로필'),
];

void main() {
  /// 탭을 누르면 고른 탭이 바뀌는 막대
  Future<void> pumpBar(WidgetTester tester) {
    var selected = 0;
    return tester.pumpWidget(
      MaterialApp(
        theme: gwittimTheme(),
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            bottomNavigationBar: GwTabBar(
              tabs: tabs,
              selected: selected,
              onSelect: (i) => setState(() => selected = i),
            ),
          ),
        ),
      ),
    );
  }

  Color? colorOf(WidgetTester tester, String label) => tester.widget<Text>(find.text(label)).style!.color;
  const c = GwColors.light;

  testWidgets('바닥에 붙은 탭: 고른 탭은 채운 아이콘과 진한 색, 누르면 색이 짧게 바뀐다', (tester) async {
    await pumpBar(tester);
    expect(tester.getBottomLeft(find.byType(GwTabBar)).dy, tester.getSize(find.byType(Scaffold)).height);
    expect(colorOf(tester, '홈'), c.tabActive);
    expect(colorOf(tester, '저장'), c.onTab);
    expect(find.byIcon(Icons.home_rounded), findsOneWidget);
    expect(find.byIcon(Icons.bookmark_border_rounded), findsOneWidget);
    expect(
      tester.getSemantics(find.text('홈')),
      isSemantics(label: '홈', isButton: true, isSelected: true, hasTapAction: true),
    );

    await tester.tap(find.text('저장'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(colorOf(tester, '저장'), isNot(anyOf(c.onTab, c.tabActive))); // 바뀌는 중

    await tester.pumpAndSettle();
    expect(colorOf(tester, '저장'), c.tabActive);
    expect(colorOf(tester, '홈'), c.onTab);
    expect(find.byIcon(Icons.bookmark_rounded), findsOneWidget);
    expect(find.byIcon(Icons.home_outlined), findsOneWidget);
    expect(tester.getSemantics(find.text('저장')), isSemantics(label: '저장', isSelected: true));
  });

  testWidgets('애니메이션 줄이기 설정이면 색이 바로 바뀐다', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpBar(tester);
    await tester.tap(find.text('프로필'));
    await tester.pump();
    await tester.pump();
    expect(colorOf(tester, '프로필'), c.tabActive);
  });

  testWidgets('목록 끝은 탭 막대에 가리지 않는다', (tester) async {
    tester.view.padding = const FakeViewPadding(bottom: 48); // 제스처 막대
    addTearDown(tester.view.reset);
    final repo = SampleNoticeRepository();
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
    final barTop = tester.getTopLeft(find.byType(GwTabBar)).dy;

    Future<void> toEnd(Type screen) async {
      final list = find.descendant(of: find.byType(screen), matching: find.byType(Scrollable)).first;
      await tester.fling(list, const Offset(0, -5000), 5000);
      await tester.pumpAndSettle();
    }

    await toEnd(HomeScreen);
    expect(tester.getBottomLeft(find.textContaining('합격 가능성을 뜻하지 않아요')).dy, lessThanOrEqualTo(barTop));

    await tester.tap(find.text('프로필'));
    await tester.pumpAndSettle();
    await toEnd(ProfileScreen);
    expect(tester.getBottomLeft(find.text('시스템 설정을 고르면 기기 화면 모드를 따라가요.')).dy, lessThanOrEqualTo(barTop));
  });
}
