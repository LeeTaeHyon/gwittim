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
  testWidgets('캡슐 탭: 누르면 그 탭을 고르고, 고른 탭만 라임 면', (tester) async {
    final picked = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: gwittimTheme(),
        home: Scaffold(
          bottomNavigationBar: GwTabBar(tabs: tabs, selected: 0, onSelect: picked.add),
        ),
      ),
    );
    await tester.tap(find.text('저장'));
    expect(picked, [1]);

    Color? fill(String label) =>
        tester.widget<Material>(find.ancestor(of: find.text(label), matching: find.byType(Material)).first).color;
    expect(fill('홈'), GwColors.light.lime);
    expect(fill('저장'), Colors.transparent);
    expect(
      tester.getSemantics(find.text('홈')),
      matchesSemantics(
        label: '홈',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        hasTapAction: true,
        isFocusable: true,
        hasFocusAction: true,
      ),
    );
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
