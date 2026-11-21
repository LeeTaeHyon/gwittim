import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/main.dart';
import 'package:gwittim/ui/briefing_data.dart';
import 'package:gwittim/ui/briefing_screen.dart';
import 'package:gwittim/ui/briefing_stats.dart';
import 'package:gwittim/ui/components.dart';
import 'package:gwittim/ui/home_screen.dart';
import 'package:gwittim/ui/icons.dart';
import 'package:gwittim/ui/notices_screen.dart';
import 'package:gwittim/ui/theme.dart';

import 'finders.dart';

final today = DateTime(2026, 10, 17);

DateInfo day(String date) => DateInfo(date: date, time: null, timezone: null, precision: 'date', evidence: date);

NoticeSummary summary(
  String id, {
  String? deadline,
  String category = 'contest',
  String? published,
  String? sourceUrl = 'https://example.invalid/x',
}) => NoticeSummary(
  noticeId: id,
  noticeVersion: 1,
  title: id,
  category: category,
  sourceUrl: sourceUrl,
  published: published == null ? null : day(published),
  applicationDeadline: deadline == null ? null : day(deadline),
  deadlineNote: null,
  lifecycleStatus: 'open',
);

RecommendationEntry entry(
  String id, {
  String? deadline,
  List<String> reasons = const [],
  String status = 'needs_check',
  String category = 'contest',
  String? published,
  String? sourceUrl = 'https://example.invalid/x',
}) => RecommendationEntry(
  recommendation: Recommendation(noticeId: id, score: null, eligibilityStatus: status, reasonCodes: reasons),
  notice: summary(id, deadline: deadline, category: category, published: published, sourceUrl: sourceUrl),
);

SavedEntry savedOne(String id, {String? deadline, String? was}) => SavedEntry(
  saved: SavedNotice(
    noticeId: id,
    savedAt: today,
    savedNoticeVersion: 1,
    savedDeadlineSnapshot: was == null ? null : day(was),
  ),
  notice: summary(id, deadline: deadline),
);

RecommendationList list(List<RecommendationEntry> items) =>
    RecommendationList(mode: 'personalized', items: items, generatedAt: today);

Future<SampleNoticeRepository> loaded(WidgetTester tester) async {
  final repo = SampleNoticeRepository();
  await tester.runAsync(repo.preload);
  return repo;
}

void reduceMotion(WidgetTester tester) {
  tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

void bigScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> pumpApp(WidgetTester tester, BriefingStore store) async {
  await tester.pumpWidget(
    GwittimApp(repository: await loaded(tester), openUrl: (_) async => true, today: today, briefingStore: store),
  );
}

void main() {
  group('겹치지 않는 공고 수와 숫자 칸', () {
    test('같은 공고가 여러 소식에 있어도 한 건으로 센다', () {
      final b = buildBriefing(
        list([
          entry('겹침', deadline: '2026-10-18', reasons: ['interest_match'], published: '2026-10-16'),
          entry('임박', deadline: '2026-10-21', reasons: ['interest_match']),
          entry('직무', reasons: ['role_match']),
          entry('관련없음', deadline: '2026-10-19'), // 맞춤 추천이라 마감 임박 후보가 아니다
        ]),
        [
          savedOne('겹침', deadline: '2026-10-18', was: '2026-10-18'),
          savedOne('바뀜', deadline: '2026-10-25', was: '2026-10-22'),
        ],
        today,
        hasInterests: true,
      );
      expect(b.urgentIds, {'겹침', '임박'});
      expect(b.savedSoon.map((e) => e.notice.noticeId), ['겹침']);
      expect(b.fresh.map((e) => e.notice.noticeId), ['겹침']);
      expect(b.career.map((e) => e.notice.noticeId), ['직무']);
      expect(b.changed.map((e) => e.notice.noticeId), ['바뀜']);
      // 겹침, 임박, 직무, 바뀜 (소식별 합 6건이 아니라 4건)
      expect(distinctNoticeCount(b), 4);
    });

    test('졸업생 진로 추천은 수에는 넣고 숫자 칸에는 넣지 않는다', () {
      final e = entry('추천', deadline: '2026-10-20', reasons: ['major_prior_match']);
      final b = Briefing(majorPick: e);
      expect(distinctNoticeCount(b), 1);
      expect(briefingStats(b), isEmpty);
    });

    test('칸은 우선순위대로 0건을 빼고 최대 3칸', () {
      final one = entry('a', deadline: '2026-10-20', reasons: ['interest_match']);
      final b = Briefing(
        urgentIds: {'a', 'b'},
        savedSoon: [savedOne('s', deadline: '2026-10-18')],
        fresh: [one],
        career: [one],
        changed: [savedOne('c', deadline: '2026-10-25', was: '2026-10-22')],
      );
      expect(
        [for (final s in briefingStats(b)) (s.kind, s.count)],
        [(BriefingStatKind.urgent, 2), (BriefingStatKind.savedSoon, 1), (BriefingStatKind.fresh, 1)],
      );
      // 마감 임박이 0건이면 뒤 칸이 앞으로
      final c = Briefing(fresh: [one], changed: b.changed);
      expect([for (final s in briefingStats(c)) s.kind], [BriefingStatKind.fresh, BriefingStatKind.changed]);
    });

    test('마감 변경만 있으면 제목이 달라진다', () {
      final changed = [savedOne('c', deadline: '2026-10-25', was: '2026-10-22')];
      expect(Briefing(changed: changed).onlyChanged, isTrue);
      expect(Briefing(changed: changed, urgentIds: {'a'}).onlyChanged, isFalse);
    });

    testWidgets('머리의 숫자 칸은 공유하는 위젯이라 0건 칸이 없고 이름과 개수가 읽힌다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: gwittimTheme(),
          home: BriefingScreen(
            briefing: Briefing(
              urgentIds: {'a', 'b'},
              fresh: [
                entry('n', reasons: ['interest_match']),
              ],
            ),
            today: today,
            onOpenNotice: (_, _) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder inRow(String text) => find.descendant(of: find.byType(BriefingStatRow), matching: find.text(text));
      expect(inRow('마감 임박'), findsOneWidget);
      expect(inRow('새 공고'), findsOneWidget);
      expect(inRow('저장 곧 마감'), findsNothing);
      expect(inRow('진로 관련'), findsNothing);
      expect(inRow('2'), findsOneWidget);
    });
  });

  group('홈 오늘의 귀띔 카드와 도착 장면', () {
    testWidgets('안 열었으면 새 소식 + 브리핑 열기, 도착 장면 뒤 열었으면 브리핑 다시 보기', (tester) async {
      final store = MemoryBriefingStore();
      await pumpApp(tester, store);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // 브리핑 화면 아래 홈
      expect(find.text('브리핑 열기', skipOffstage: false), findsOneWidget);
      expect(find.text('새 소식', skipOffstage: false), findsOneWidget);
      expect(find.text('브리핑 다시 보기', skipOffstage: false), findsNothing);

      await tester.pumpAndSettle();
      await tester.tap(find.text('확인'));
      await tester.pumpAndSettle();
      expect(find.text('브리핑 다시 보기'), findsOneWidget);
      expect(find.text('새 소식'), findsNothing);
      expect(find.text('오늘 확인할'), findsOneWidget);
      expect(await store.shownOn(today), isTrue);
    });

    testWidgets('도착 장면: 말풍선 → 날짜 → 확인할 공고 N건 → 사라진 뒤 브리핑, 화면 읽기 이름', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpApp(tester, MemoryBriefingStore());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final scene = find.byWidgetPredicate(
        (w) => w is Semantics && (w.properties.label ?? '').startsWith('오늘의 귀띔 도착, 확인할 공고 '),
      );
      expect(scene, findsOneWidget);
      expect(findTextContaining('· 오늘의 귀띔'), findsOneWidget);
      expect(find.text('10월 17일 토요일 · 오늘의 귀띔'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 2600)); // 장면이 거의 끝남
      await tester.pump(const Duration(milliseconds: 300));
      expect(scene, findsNothing);
      expect(find.byType(BriefingScreen), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('주요 소식'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('장면 아무 곳이나 누르면 바로 브리핑', (tester) async {
      await pumpApp(tester, MemoryBriefingStore());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(findTextContaining('· 오늘의 귀띔'), findsOneWidget);
      await tester.tapAt(const Offset(40, 300));
      await tester.pump();
      expect(findTextContaining('· 오늘의 귀띔'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('주요 소식'), findsOneWidget);
    });

    testWidgets('애니메이션 줄이기면 장면 없이 바로 브리핑', (tester) async {
      reduceMotion(tester);
      await pumpApp(tester, MemoryBriefingStore());
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(findTextContaining('· 오늘의 귀띔'), findsNothing);
      expect(find.byType(BriefingScreen), findsOneWidget);
      expect(find.text('주요 소식'), findsOneWidget);
    });

    testWidgets('홈 카드에서 여는 브리핑은 장면 없이 열리고, 닫으면 카드는 그대로 다시 보기', (tester) async {
      bigScreen(tester);
      await pumpApp(tester, MemoryBriefingStore(alwaysShown: true));
      await tester.pumpAndSettle();
      expect(find.text('브리핑 열기'), findsNothing);
      await tester.tap(find.text('브리핑 다시 보기'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(BriefingScreen), findsOneWidget);
      expect(findTextContaining('· 오늘의 귀띔'), findsNothing);
      expect(find.text('주요 소식'), findsOneWidget);
      await tester.pumpAndSettle();
      await tester.tap(find.text('확인'));
      await tester.pumpAndSettle();
      expect(find.text('브리핑 다시 보기'), findsOneWidget);
    });

    testWidgets('카드 숫자 칸은 0건을 숨기고, 칸 이름과 개수가 읽힌다', (tester) async {
      bigScreen(tester);
      final semantics = tester.ensureSemantics();
      await pumpApp(tester, MemoryBriefingStore(alwaysShown: true));
      await tester.pumpAndSettle();
      expect(find.text('마감 임박'), findsNothing); // 샘플은 7일 안 마감이 없다
      expect(find.text('저장 곧 마감'), findsNothing);
      expect(find.text('마감 변경'), findsNothing);
      expect(find.text('새 공고'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'새 공고 \d+건')), findsOneWidget);
      semantics.dispose();
    });
  });

  group('홈 공고 카드: 분류 아이콘과 조건 상태', () {
    Future<void> pumpCards(WidgetTester tester, List<Widget> cards) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: gwittimTheme(),
          home: Scaffold(body: ListView(children: cards)),
        ),
      );
    }

    NoticeCard card(RecommendationEntry e, {bool home = true, String category = '공모전'}) =>
        NoticeCard(entry: e, category: category, today: today, home: home, onTap: () {});

    testWidgets('분류 아이콘(분류 이름, 분류색)과 상태 원 아이콘, 글자 칩은 없다', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpCards(tester, [
        card(entry('충족', deadline: '2026-11-30', status: 'met')),
        card(entry('확인', deadline: '2026-11-30'), category: '공모전'),
        card(entry('미충족', deadline: '2026-11-30', status: 'not_met')),
      ]);
      final icons = tester.widgetList<Icon>(find.byType(Icon)).toList();
      final category = icons.where((i) => i.icon == Icons.emoji_events_rounded).toList();
      expect(category, hasLength(3));
      expect(category.first.size, 26);
      expect(category.first.color, GwColors.light.category('contest'));
      expect(category.first.semanticLabel, '공모전');
      expect(find.byType(Pill), findsNothing);
      expect(find.bySemanticsLabel(RegExp('조건 충족')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('확인 필요')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('조건 미충족')), findsOneWidget);
      expect(find.text('조건 충족'), findsNothing);
      for (final (status, icon) in [
        ('met', Icons.check_rounded),
        ('needs_check', Icons.question_mark_rounded),
        ('not_met', Icons.close_rounded),
      ]) {
        final dot = find.byWidgetPredicate((w) => w is EligibilityDot && w.status == status);
        expect(find.descendant(of: dot, matching: find.byIcon(icon)), findsOneWidget);
        expect(tester.getSize(dot), const Size(26, 26));
      }
      semantics.dispose();
    });

    testWidgets('알 수 없는 분류는 기타 아이콘', (tester) async {
      await pumpCards(tester, [card(entry('x', category: 'mystery'))]);
      expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);
      expect(tester.widget<Icon>(find.byIcon(Icons.more_horiz_rounded)).color, GwColors.light.category('other'));
    });

    testWidgets('7일 안 마감이면 D-day 칩과 상태 원이 나란히, 이유 줄 끝의 확인 필요 글자는 없다', (tester) async {
      await pumpCards(tester, [
        card(entry('임박', deadline: '2026-10-20', reasons: ['interest_match'])),
      ]);
      expect(find.text('D-3'), findsOneWidget);
      expect(find.byType(EligibilityDot), findsOneWidget);
      expect(findTextContaining('조건 확인 필요'), findsNothing);
      final dday = tester.getRect(find.text('D-3'));
      final dot = tester.getRect(find.byType(EligibilityDot));
      expect(dot.left - tester.getRect(find.ancestor(of: find.text('D-3'), matching: find.byType(Pill))).right, 6);
      expect((dday.center.dy - dot.center.dy).abs(), lessThan(1));
    });

    testWidgets('알림톡 공고는 분류 아이콘 칸 없이 말풍선 카드와 말풍선 아이콘', (tester) async {
      await pumpCards(tester, [card(entry('알림톡', deadline: '2026-11-30', sourceUrl: null))]);
      expect(find.byIcon(Icons.emoji_events_rounded), findsNothing);
      expect(find.byType(GwIcon), findsOneWidget);
      expect(tester.widget<GwCard>(find.byType(GwCard)).bubble, isTrue);
    });

    testWidgets('홈 옵션이 없으면(공고 탭·저장함) 분류 아이콘 없이 글자 칩 그대로', (tester) async {
      await pumpCards(tester, [card(entry('탭', deadline: '2026-11-30', status: 'met'), home: false)]);
      expect(find.byIcon(Icons.emoji_events_rounded), findsNothing);
      expect(find.byType(EligibilityDot), findsNothing);
      expect(find.text('조건 충족'), findsOneWidget);
    });

    testWidgets('앱의 홈은 홈 모양, 공고 탭은 글자 칩', (tester) async {
      bigScreen(tester);
      await pumpApp(tester, MemoryBriefingStore(alwaysShown: true));
      await tester.pumpAndSettle();
      final homeCards = find.descendant(of: find.byType(HomeScreen), matching: find.byType(NoticeCard));
      expect(homeCards, findsNWidgets(3));
      expect(find.descendant(of: homeCards, matching: find.byType(EligibilityDot)), findsNWidgets(3));
      expect(find.descendant(of: homeCards, matching: find.byType(Pill)), findsNothing);

      await tester.tap(find.text('공고'));
      await tester.pumpAndSettle();
      final tabCards = find.descendant(of: find.byType(NoticesScreen), matching: find.byType(NoticeCard));
      expect(tabCards, findsWidgets);
      expect(find.descendant(of: tabCards, matching: find.byType(EligibilityDot)), findsNothing);
      expect(find.descendant(of: tabCards, matching: find.byType(Pill)), findsWidgets);
    });
  });

  testWidgets('다가오는 마감 줄: 월과 큰 날짜 블록, 화면 읽기에서는 뺀다', (tester) async {
    bigScreen(tester);
    await pumpApp(tester, MemoryBriefingStore(alwaysShown: true));
    await tester.pumpAndSettle();
    expect(find.text('10월'), findsWidgets);
    final block = find.ancestor(of: find.text('10월').first, matching: find.byType(ExcludeSemantics));
    expect(block, findsWidgets);
    expect(tester.getSize(find.ancestor(of: find.text('10월').first, matching: find.byType(Container)).last).width, 44);
  });

  testWidgets('글꼴 2배에서 섹션 제목이 어절 중간에서 끊기지 않고 오른쪽 글이 아랫줄로 간다', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3; // 폭 360
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: gwittimTheme(),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(360, 800), textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: SectionTitle('다가오는 마감', trailing: Text('맞춤 공고 · 앞으로 2주')),
            ),
          ),
        ),
      ),
    );
    final title = tester.getRect(find.text('다가오는 마감'));
    final trailing = tester.getRect(find.text('맞춤 공고 · 앞으로 2주'));
    expect(title.height, lessThan(19 * 2 * 1.6)); // 한 줄
    expect(trailing.top, greaterThanOrEqualTo(title.bottom - 1)); // 아랫줄
  });
}
