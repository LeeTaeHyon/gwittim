import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/main.dart';
import 'package:gwittim/ui/briefing_data.dart';
import 'package:gwittim/ui/calendar_screen.dart';
import 'package:gwittim/ui/icons.dart';
import 'package:gwittim/ui/report_screen.dart';

import 'finders.dart';

final today = DateTime(2026, 10, 17);
const projectTitle = '[합성 샘플] 컴퓨터공학과 프로젝트 발표회 참가자 모집';

DateInfo at(String date, [String? time]) => DateInfo(
  date: date,
  time: time,
  timezone: time == null ? null : 'Asia/Seoul',
  precision: time == null ? 'date' : 'minute',
  evidence: date,
);

NoticeSummary summary(String id, {String? deadline, String? time, String lifecycle = 'open'}) => NoticeSummary(
  noticeId: id,
  noticeVersion: 1,
  title: id,
  category: 'contest',
  sourceUrl: 'https://example.invalid/$id',
  published: null,
  applicationDeadline: deadline == null ? null : at(deadline, time),
  deadlineNote: null,
  lifecycleStatus: lifecycle,
);

RecommendationEntry entry(String id, {String? deadline, String? time, List<String> reasons = const []}) =>
    RecommendationEntry(
      recommendation: Recommendation(noticeId: id, score: null, eligibilityStatus: 'met', reasonCodes: reasons),
      notice: summary(id, deadline: deadline, time: time),
    );

SavedEntry saved(String id, {String? deadline, String lifecycle = 'open'}) => SavedEntry(
  saved: SavedNotice(noticeId: id, savedAt: today, savedNoticeVersion: 1, savedDeadlineSnapshot: null),
  notice: summary(id, deadline: deadline, lifecycle: lifecycle),
);

RecommendationList list(List<RecommendationEntry> items, {bool personalized = true}) =>
    RecommendationList(mode: personalized ? 'personalized' : 'latest', items: items, generatedAt: today);

void main() {
  group('달력에 놓는 공고', () {
    test('맞춤 공고는 관련 공고만, 저장한 공고는 관련 여부와 상관없이. 둘 다면 하나로 합친다', () {
      final items = calendarItems(
        list([
          entry('관련', deadline: '2026-10-20', reasons: ['interest_match']),
          entry('무관', deadline: '2026-10-20', reasons: ['deadline_timing']),
          entry('관련+저장', deadline: '2026-10-22', reasons: ['role_match']),
          entry('날짜 없음', reasons: ['major_match']),
        ]),
        [
          saved('관련+저장', deadline: '2026-10-22'),
          saved('저장만', deadline: '2026-10-22'),
          saved('삭제됨', deadline: '2026-10-22', lifecycle: 'removed'),
          saved('지난 저장', deadline: '2026-10-01', lifecycle: 'closed'),
        ],
      );
      expect(items.keys.toSet(), {DateTime(2026, 10, 20), DateTime(2026, 10, 22), DateTime(2026, 10, 1)});
      expect(items[DateTime(2026, 10, 20)]!.map((i) => i.notice.noticeId), ['관련']);
      final both = items[DateTime(2026, 10, 22)]!;
      expect(both.map((i) => (i.notice.noticeId, i.saved)), [('관련+저장', true), ('저장만', true)]);
      expect(both.first.recommendation, isNotNull); // 리포트에 판정을 넘길 수 있게 남긴다
      expect(items[DateTime(2026, 10, 1)]!.single.notice.lifecycleStatus, 'closed'); // 지난 달도 볼 수 있다
    });

    test('최신 모드면 마감 후보 전부, 같은 날은 시각이 확인된 공고 먼저', () {
      final items = calendarItems(
        list([
          entry('나', deadline: '2026-10-20'),
          entry('가', deadline: '2026-10-20', time: '17:00'),
          entry('다', deadline: '2026-10-20', time: '09:00'),
        ], personalized: false),
        const [],
      );
      expect(items[DateTime(2026, 10, 20)]!.map((i) => i.notice.noticeId), ['다', '가', '나']);
      expect(deadlineCandidates(list(const [], personalized: false)), isEmpty);
    });
  });

  testWidgets('달력 탭: 오늘이 고른 날, 마감일을 누르면 그날 공고, 달을 넘기고 오늘로 돌아온다', (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = SampleNoticeRepository();
    await tester.runAsync(repo.preload);
    await tester.pumpWidget(
      GwittimApp(
        repository: repo,
        openUrl: (_) async => true,
        today: today,
        briefingStore: MemoryBriefingStore(alwaysShown: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('달력'));
    await tester.pumpAndSettle();

    expect(find.text('2026년 10월'), findsOneWidget);
    expect(find.text('10월 17일(토) 마감'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^10월 17일 토요일, 오늘')), findsOneWidget);
    final todayButton = find.widgetWithText(TextButton, '오늘');
    bool todayShown() =>
        tester.widget<Visibility>(find.ancestor(of: todayButton, matching: find.byType(Visibility)).first).visible;
    expect(todayShown(), isFalse); // 이번 달이면 '오늘' 버튼은 자리만 차지한다

    // 10/30에는 맞춤 공고(발표회)가 있다
    expect(find.bySemanticsLabel(RegExp(r'^10월 30일 금요일, 마감 \d+건')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('day-10-30')));
    await tester.pumpAndSettle();
    expect(find.text('10월 30일(금) 마감'), findsOneWidget);
    expect(findText(projectTitle), findsOneWidget);
    expect(find.text('D-13 · 17:00 마감 · 행사'), findsOneWidget);

    await tester.tap(find.byTooltip('다음 달'));
    await tester.pumpAndSettle();
    expect(find.text('2026년 11월'), findsOneWidget);
    expect(findText(projectTitle), findsNothing);
    expect(todayShown(), isTrue);
    await tester.tap(todayButton);
    await tester.pumpAndSettle();
    expect(find.text('2026년 10월'), findsOneWidget);
    expect(find.text('10월 17일(토) 마감'), findsOneWidget);

    // 공고를 누르면 리포트, 판정을 함께 넘긴다
    await tester.tap(find.byKey(const ValueKey('day-10-30')));
    await tester.pumpAndSettle();
    await tester.tap(findText(projectTitle));
    await tester.pumpAndSettle();
    expect(find.byType(ReportScreen), findsOneWidget);
    expect(find.text('조건 충족'), findsOneWidget);
  });

  testWidgets('저장한 공고는 채운 점과 북마크로 보인다', (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = SampleNoticeRepository();
    await tester.runAsync(repo.preload);
    final first = (await repo.listRecommendations()).items.firstWhere((e) => e.notice.title == projectTitle);
    await repo.saveNotice(first.notice.noticeId);
    await tester.pumpWidget(
      GwittimApp(
        repository: repo,
        openUrl: (_) async => true,
        today: today,
        briefingStore: MemoryBriefingStore(alwaysShown: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('달력'));
    await tester.pumpAndSettle();
    final cell = find.byKey(const ValueKey('day-10-30'));
    expect(find.descendant(of: cell, matching: find.byKey(const ValueKey('dot-saved'))), findsOneWidget);
    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((w) => w is GwIcon && w.glyph == GwGlyph.saved && w.filled), findsOneWidget);
  });
}
