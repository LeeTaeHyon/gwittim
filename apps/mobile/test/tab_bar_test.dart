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
  (icon: Icons.home_rounded, label: '홈'),
  (icon: Icons.bookmark_rounded, label: '저장'),
  (icon: Icons.person_rounded, label: '프로필'),
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

  final capsule = find.byKey(const ValueKey('tab-capsule'));
  Finder slot(String label) => find.ancestor(of: find.text(label), matching: find.byType(GestureDetector)).first;

  testWidgets('캡슐 탭: 고른 칸 가운데에 이름 폭만 한 캡슐, 누르면 미끄러져 옮겨 간다', (tester) async {
    await pumpBar(tester);
    expect(tester.getCenter(capsule).dx, moreOrLessEquals(tester.getCenter(slot('홈')).dx));
    expect(tester.getSize(capsule).width, lessThan(tester.getSize(slot('홈')).width));
    expect(
      tester.getSemantics(find.text('홈')),
      isSemantics(label: '홈', isButton: true, isSelected: true, hasTapAction: true),
    );

    await tester.tap(find.text('저장'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final moving = tester.getCenter(capsule).dx;
    expect(moving, greaterThan(tester.getCenter(slot('홈')).dx));
    expect(moving, lessThan(tester.getCenter(slot('저장')).dx));

    await tester.pumpAndSettle();
    expect(tester.getCenter(capsule).dx, moreOrLessEquals(tester.getCenter(slot('저장')).dx));
    expect(tester.getSemantics(find.text('저장')), isSemantics(label: '저장', isSelected: true));
  });

  testWidgets('애니메이션 줄이기 설정이면 캡슐이 바로 옮겨 간다', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpBar(tester);
    await tester.tap(find.text('프로필'));
    await tester.pump();
    await tester.pump();
    expect(tester.getCenter(capsule).dx, moreOrLessEquals(tester.getCenter(slot('프로필')).dx));
  });

  testWidgets('탭 막대가 떠 있어도 목록 끝은 막대 위에서 보인다', (tester) async {
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
