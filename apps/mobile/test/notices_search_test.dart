import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/ui/notices_screen.dart';
import 'package:gwittim/ui/theme.dart';

import 'finders.dart';

/// 추천 목록 요청 횟수를 센다 (새로 고침이 실제로 다시 받는지).
class CountingRepository extends SampleNoticeRepository {
  int lists = 0;

  @override
  Future<RecommendationList> listRecommendations() {
    lists++;
    return super.listRecommendations();
  }
}

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

Finder chip(String label) => find.ancestor(of: findText(label), matching: find.byType(InkWell)).first;

void main() {
  testWidgets('제목 아래 칩 줄이 늘 있고, 칩·검색으로 거른다 (D-026)', (tester) async {
    await pumpNotices(tester, SampleNoticeRepository());
    expect(findText('나에게 맞는 공고'), findsOneWidget);
    expect(findText('추천순'), findsOneWidget);
    expect(chip('전체').hitTestable(), findsOneWidget); // 당기지 않아도 보인다
    expect(findTextContaining('발표회'), findsOneWidget);

    // 칩이 먼저 나온다 (카드 첫 줄에도 같은 분류 글자가 있음)
    await tester.tap(chip('공모전·경진대회'));
    await tester.pumpAndSettle();
    expect(findText('2건'), findsOneWidget);
    expect(findTextContaining('발표회'), findsNothing);
    expect(findTextContaining('글쓰기 공모전'), findsOneWidget);

    // 검색 칩 → 검색 칸 (띄어쓰기 무시)
    await tester.tap(chip('검색'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '아이디어경진');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(findText('1건'), findsOneWidget);
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
    expect(findText('추천순'), findsOneWidget);
    expect(findTextContaining('발표회'), findsOneWidget);
  });

  testWidgets('당기면 새로 고침만 한다', (tester) async {
    final repo = CountingRepository();
    await pumpNotices(tester, repo);
    final before = repo.lists;
    await tester.fling(findText('나에게 맞는 공고'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(repo.lists, before + 1);
    expect(findText('나에게 맞는 공고'), findsOneWidget);
    expect(chip('전체').hitTestable(), findsOneWidget);
  });

  testWidgets('카드 첫 줄에 분류와 마감, 조건 상태는 오른쪽 칩에만 (체크 없음)', (tester) async {
    await pumpNotices(tester, LongRepository(1));
    expect(findTextContaining('공모전·경진대회 · '), findsWidgets);
    expect(findTextContaining('마감'), findsWidgets);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    expect(findText('공고에 마감일 없음'), findsNothing);
  });
}
