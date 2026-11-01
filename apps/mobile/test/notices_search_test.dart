import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/ui/notices_screen.dart';
import 'package:gwittim/ui/theme.dart';

import 'finders.dart';

/// 샘플 공고를 [copies]배로 늘린다 (목록이 화면보다 길 때도 같은지 보려고).
class LongRepository extends SampleNoticeRepository {
  LongRepository(this.copies);

  final int copies;

  @override
  Future<RecommendationList> listRecommendations() async {
    final list = await super.listRecommendations();
    return RecommendationList(
      mode: list.mode,
      generatedAt: list.generatedAt,
      items: [
        for (var k = 0; k < copies; k++)
          for (final e in list.items)
            RecommendationEntry(
              recommendation: e.recommendation,
              notice: NoticeSummary(
                noticeId: '${e.notice.noticeId}_$k',
                noticeVersion: e.notice.noticeVersion,
                title: e.notice.title,
                category: e.notice.category,
                sourceUrl: e.notice.sourceUrl,
                published: e.notice.published,
                applicationDeadline: e.notice.applicationDeadline,
                deadlineNote: e.notice.deadlineNote,
                lifecycleStatus: e.notice.lifecycleStatus,
              ),
            ),
      ],
    );
  }
}

Future<void> pumpNotices(WidgetTester tester, SampleNoticeRepository repo) async {
  await tester.runAsync(repo.preload);
  await tester.pumpWidget(
    MaterialApp(
      theme: gwittimTheme(),
      home: Scaffold(
        body: NoticesScreen(repository: repo, openUrl: (_) async => true, today: DateTime(2026, 10, 17)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 머리를 끌어내렸다 놓아 칩으로 바꾼다 (새로 고침까지는 당기지 않음).
Future<void> pullToChips(WidgetTester tester) async {
  await tester.drag(findText('나에게 맞는 공고'), const Offset(0, 60));
  await tester.pumpAndSettle();
}

Finder chip(String label) => find.ancestor(of: findText(label), matching: find.byType(InkWell)).first;

void main() {
  testWidgets('끌어내리면 제목 자리에 칩이 나오고, 칩·검색으로 거른다 (D-026)', (tester) async {
    await pumpNotices(tester, SampleNoticeRepository());
    expect(findText('추천순'), findsOneWidget);
    expect(findTextContaining('발표회'), findsOneWidget);
    expect(chip('전체').hitTestable(), findsNothing); // 처음에는 숨어 있다

    await pullToChips(tester);
    expect(chip('전체').hitTestable(), findsOneWidget);
    expect(findText('나에게 맞는 공고').hitTestable(), findsNothing); // 제목은 사라짐

    // 칩 자리 첫 칸이 칩 (카드에도 같은 분류 글자가 있어 첫 것)
    await tester.tap(chip('공모전·경진대회'));
    await tester.pumpAndSettle();
    expect(findText('2건 · 추천순'), findsOneWidget);
    expect(findTextContaining('발표회'), findsNothing);
    expect(findTextContaining('글쓰기 공모전'), findsOneWidget);

    // 검색 칩 → 검색 칸 (띄어쓰기 무시)
    await tester.tap(chip('검색'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '아이디어경진');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(findText('1건 · 추천순'), findsOneWidget);
    expect(findTextContaining('아이디어 경진대회'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '없는말');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(findText('찾는 공고가 없습니다'), findsOneWidget);

    // 검색 닫기 → 칩 줄, '전체' → 처음 목록
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    await tester.tap(chip('전체'));
    await tester.pumpAndSettle();
    expect(findTextContaining('발표회'), findsOneWidget);
    expect(findTextContaining('건 · 추천순'), findsNothing);
  });

  testWidgets('새로 고침까지 당기면 칩이 남지 않는다, 거르는 중이면 남는다', (tester) async {
    await pumpNotices(tester, SampleNoticeRepository());
    await tester.fling(findText('나에게 맞는 공고'), const Offset(0, 400), 1000); // 새로 고침
    await tester.pumpAndSettle();
    expect(findText('나에게 맞는 공고').hitTestable(), findsOneWidget);
    expect(chip('전체').hitTestable(), findsNothing);

    await pullToChips(tester);
    await tester.tap(chip('공모전·경진대회'));
    await tester.pumpAndSettle();
    await tester.fling(findText('2건 · 추천순'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(chip('전체').hitTestable(), findsOneWidget);
    expect(findText('2건 · 추천순'), findsOneWidget);
  });

  testWidgets('조금만 당겼다 놓으면 제목 그대로, 목록이 길어도 같다', (tester) async {
    await pumpNotices(tester, LongRepository(6));
    expect(chip('전체').hitTestable(), findsNothing);

    await tester.drag(findText('나에게 맞는 공고'), const Offset(0, 15));
    await tester.pumpAndSettle();
    expect(findText('나에게 맞는 공고').hitTestable(), findsOneWidget);
    expect(chip('전체').hitTestable(), findsNothing);

    await pullToChips(tester);
    expect(chip('전체').hitTestable(), findsOneWidget);
  });
}
