import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/main.dart';
import 'package:gwittim/ui/briefing_data.dart';
import 'package:gwittim/ui/components.dart';
import 'package:gwittim/ui/home_screen.dart';
import 'package:gwittim/ui/icons.dart';
import 'package:gwittim/ui/notices_screen.dart';
import 'package:gwittim/ui/theme.dart';

const tabs = <GwTab>[
  (glyph: GwGlyph.today, label: '오늘'),
  (glyph: GwGlyph.notices, label: '공고'),
  (glyph: GwGlyph.saved, label: '저장함'),
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
  GwIcon iconOf(WidgetTester tester, String label) => tester.widget<GwIcon>(
    find.descendant(
      of: find.ancestor(of: find.text(label), matching: find.byType(Column)).first,
      matching: find.byType(GwIcon),
    ),
  );
  const c = GwColors.light;

  testWidgets('바닥에 붙은 탭: 직접 그린 아이콘, 고른 탭은 채운 아이콘과 진한 색, 누르면 색이 짧게 바뀐다', (tester) async {
    await pumpBar(tester);
    expect(tester.getBottomLeft(find.byType(GwTabBar)).dy, tester.getSize(find.byType(Scaffold)).height);
    expect(find.byType(Icon), findsNothing); // Material 기본 아이콘을 쓰지 않는다
    expect([for (final t in tabs) iconOf(tester, t.label).glyph], [GwGlyph.today, GwGlyph.notices, GwGlyph.saved]);
    expect(colorOf(tester, '오늘'), c.tabActive);
    expect(colorOf(tester, '공고'), c.onTab);
    expect(iconOf(tester, '오늘').filled, isTrue);
    expect(iconOf(tester, '저장함').filled, isFalse);
    expect(
      tester.getSemantics(find.text('오늘')),
      isSemantics(label: '오늘', isButton: true, isSelected: true, hasTapAction: true),
    );

    await tester.tap(find.text('저장함'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(colorOf(tester, '저장함'), isNot(anyOf(c.onTab, c.tabActive))); // 바뀌는 중

    await tester.pumpAndSettle();
    expect(colorOf(tester, '저장함'), c.tabActive);
    expect(colorOf(tester, '오늘'), c.onTab);
    expect(iconOf(tester, '저장함').filled, isTrue);
    expect(iconOf(tester, '오늘').filled, isFalse);
    expect(tester.getSemantics(find.text('저장함')), isSemantics(label: '저장함', isSelected: true));
  });

  testWidgets('고른 탭 아이콘 아래 라임 점: 옮겨 가는 동안 가로로 늘었다가 줄어든다', (tester) async {
    await pumpBar(tester);
    final dot = find.byKey(const ValueKey('tab-dot'));
    Rect dotRect() => tester.getRect(dot);
    // 아이콘이 선↔채움으로 바뀌는 동안에는 둘이 겹쳐 있어서 새 아이콘(뒤쪽)을 잰다.
    Rect iconRect(String label) => tester.getRect(
      find
          .descendant(
            of: find.ancestor(of: find.text(label), matching: find.byType(Column)).first,
            matching: find.byType(GwIcon),
          )
          .last,
    );

    expect(dotRect().size, const Size(4, 4));
    expect(dotRect().center.dx, moreOrLessEquals(iconRect('오늘').center.dx));
    expect(dotRect().top, greaterThan(iconRect('오늘').bottom)); // 아이콘 아래
    expect(dotRect().bottom, lessThan(tester.getTopLeft(find.text('오늘')).dy)); // 이름 위
    final box = tester.widget<DecoratedBox>(find.descendant(of: dot, matching: find.byType(DecoratedBox)));
    expect((box.decoration as BoxDecoration).color, c.lime);

    await tester.tap(find.text('저장함'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    expect(dotRect().width, greaterThan(8)); // 가운데쯤에서 가장 길다
    expect(dotRect().center.dx, greaterThan(iconRect('오늘').center.dx));

    await tester.pumpAndSettle();
    expect(dotRect().size, const Size(4, 4));
    expect(dotRect().center.dx, moreOrLessEquals(iconRect('저장함').center.dx));
  });

  testWidgets('누름 표시는 빨리 나타나고, 손을 뗀 뒤 천천히 사라진다', (tester) async {
    await pumpBar(tester);
    double highlight() {
      final slot = find.ancestor(of: find.text('공고'), matching: find.byType(Stack)).first;
      final box = tester.widget<DecoratedBox>(find.descendant(of: slot, matching: find.byType(DecoratedBox)).first);
      return (box.decoration as BoxDecoration).color!.a;
    }

    final press = await tester.startGesture(tester.getCenter(find.text('공고')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(highlight(), greaterThan(0.05));
    await press.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(highlight(), greaterThan(0)); // 아직 남아 있다
    await tester.pumpAndSettle();
    expect(highlight(), 0);
  });

  testWidgets('애니메이션 줄이기 설정이면 색과 점이 바로 바뀐다', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpBar(tester);
    await tester.tap(find.text('저장함'));
    await tester.pump();
    await tester.pump();
    expect(colorOf(tester, '저장함'), c.tabActive);
    expect(tester.getRect(find.byKey(const ValueKey('tab-dot'))).width, 4);
  });

  testWidgets('탭을 바꾸면 화면이 좌우로 밀리며 바뀌고, 화면 상태는 유지된다', (tester) async {
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
    double x(Type screen) => tester.getTopLeft(find.byType(screen)).dx;
    final home = tester.state(find.byType(HomeScreen));

    // 오른쪽 탭으로: 새 화면은 오른쪽에서 들어오고 홈은 왼쪽으로 밀려난다
    await tester.tap(find.text('공고'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(x(NoticesScreen), greaterThan(0));
    expect(x(HomeScreen), lessThan(0));
    await tester.pumpAndSettle();
    expect(x(NoticesScreen), 0);
    expect(find.byType(HomeScreen), findsNothing); // 화면 밖으로 빠졌다

    // 왼쪽 탭으로: 홈이 왼쪽에서 들어온다
    await tester.tap(find.text('오늘'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(x(HomeScreen), lessThan(0));
    await tester.pumpAndSettle();
    expect(x(HomeScreen), 0);
    expect(tester.state(find.byType(HomeScreen)), same(home));
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
    expect(tester.getBottomLeft(find.byType(NoticeCard).last).dy, lessThanOrEqualTo(barTop));

    await tester.tap(find.text('공고'));
    await tester.pumpAndSettle();
    await toEnd(NoticesScreen);
    final last = find.descendant(of: find.byType(NoticesScreen), matching: find.byType(NoticeCard)).last;
    expect(tester.getBottomLeft(last).dy, lessThanOrEqualTo(barTop));
  });
}
