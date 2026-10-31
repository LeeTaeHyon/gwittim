import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/ui/notices_screen.dart';
import 'package:gwittim/ui/theme.dart';

/// 샘플 공고를 [copies]배로 늘린다 (목록이 화면보다 길 때 검색 칸이 숨는지 보려고).
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

/// 숨은 검색 칸·칩을 끌어내려 보이게 한다 (새로 고침까지는 당기지 않음).
Future<void> reveal(WidgetTester tester) async {
  await tester.drag(find.text('나에게 맞는 공고'), const Offset(0, 150));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('공고 탭 분류 칩과 검색 (D-026)', (tester) async {
    await pumpNotices(tester, SampleNoticeRepository());
    expect(find.text('추천순'), findsOneWidget);
    expect(find.textContaining('발표회'), findsOneWidget);

    await reveal(tester);
    await tester.tap(find.widgetWithText(InkWell, '공모전·경진대회').first); // 칩 (카드에도 같은 분류 글자가 있음)
    await tester.pumpAndSettle();
    expect(find.text('2건'), findsOneWidget);
    expect(find.textContaining('발표회'), findsNothing);
    expect(find.textContaining('글쓰기 공모전'), findsOneWidget);

    // 분류 + 검색어 (띄어쓰기 무시)
    await tester.enterText(find.byType(TextField), '아이디어경진');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('1건'), findsOneWidget);
    expect(find.textContaining('아이디어 경진대회'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '없는말');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('찾는 공고가 없습니다'), findsOneWidget);

    // 검색어를 지우고 '전체'를 고르면 처음 목록
    await tester.tap(find.byTooltip('검색어 지우기'));
    await tester.tap(find.text('전체'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('추천순'), findsOneWidget);
    expect(find.textContaining('발표회'), findsOneWidget);
  });

  testWidgets('목록이 길면 검색 칸이 처음엔 숨어 있고, 끌어내리면 나온다', (tester) async {
    await pumpNotices(tester, LongRepository(6));
    expect(find.byType(TextField).hitTestable(), findsNothing); // 화면 위로 밀려 있음
    expect(find.text('나에게 맞는 공고'), findsOneWidget);

    await reveal(tester);
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    expect(find.widgetWithText(InkWell, '전체').hitTestable(), findsOneWidget);
  });
}
