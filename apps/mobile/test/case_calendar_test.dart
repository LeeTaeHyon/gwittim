// 달력: 진행 중 지원 건 강조, 신청함 흐리게, 끝난 건 빼기, 신청 시작 줄 (care-loop-impl-spec §6)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/application_case.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/ui/calendar_screen.dart';
import 'package:gwittim/ui/components.dart';
import 'package:gwittim/ui/format.dart';
import 'package:gwittim/ui/theme.dart';

import 'case_fakes.dart';
import 'finders.dart';

final today = DateTime(2026, 11, 24, 12);

RecommendationEntry rec(NoticeSummary n) => RecommendationEntry(
  recommendation: Recommendation(noticeId: n.noticeId, score: 50, eligibilityStatus: 'met', reasonCodes: const ['interest_match']),
  notice: n,
);

RecommendationList listOf(List<NoticeSummary> ns) =>
    RecommendationList(mode: 'personalized', items: [for (final n in ns) rec(n)], generatedAt: today);

void main() {
  final prep = summaryOf('prep', deadline: dateOnly('2026-11-27'), title: '준비 공고');
  final applied = summaryOf('applied', deadline: dateOnly('2026-11-27'), title: '신청 공고');
  final skipped = summaryOf('skipped', deadline: dateOnly('2026-11-27'), title: '안 할 공고');
  final other = summaryOf('other', deadline: dateOnly('2026-11-27'), title: '가 맞춤 공고');
  final closed = summaryOf('closed', deadline: dateOnly('2026-11-30'), lifecycle: 'closed', title: '끝난 공고');

  Map<String, ApplicationCase> cases() => {
    'prep': caseOf('prep', CaseState.preparing, start: seoul('2026-11-25', '09:00')),
    'applied': caseOf('applied', CaseState.applied, start: seoul('2026-11-25', '09:00')),
    'skipped': caseOf('skipped', CaseState.skipped),
    'closed': caseOf('closed', CaseState.saved),
  };

  test('진행 중 지원 건이 그날 맨 위, 맞춤 공고, 신청함은 맨 아래·흐리게. 안 함·모집 끝남은 빠짐(추천에 있어도)', () {
    final items = calendarItems(
      listOf([other, skipped, closed]),
      [savedOf(prep), savedOf(applied), savedOf(skipped), savedOf(closed)],
      cases: cases(),
      now: today,
    );
    final day = items[DateTime(2026, 11, 27)]!;
    expect([for (final i in day) i.notice.noticeId], ['prep', 'other', 'applied']);
    expect(day.first.inProgress, isTrue);
    expect(day.last.dim, isTrue);
    expect(items[DateTime(2026, 11, 30)], isNull);
  });

  test('신청 시작 줄은 진행 중 지원 건의 시작일에만(신청함은 빼고)', () {
    final items = calendarItems(listOf([]), [savedOf(prep), savedOf(applied)], cases: cases(), now: today);
    final day = items[DateTime(2026, 11, 25)]!;
    expect([for (final i in day) (i.notice.noticeId, i.start)], [('prep', true)]);
  });

  test('신청 시작 줄은 시작일이 오늘이거나 그 뒤일 때만(지난 시작일은 없음)', () {
    final past = summaryOf('past', deadline: dateOnly('2026-11-30'), title: '지난 시작');
    final todayStart = summaryOf('todayStart', deadline: dateOnly('2026-11-30'), title: '오늘 시작');
    final items = calendarItems(listOf([]), [savedOf(past), savedOf(todayStart), savedOf(prep)], cases: {
      'past': caseOf('past', CaseState.saved, start: seoul('2026-11-23', '09:00')),
      'todayStart': caseOf('todayStart', CaseState.preparing, start: dateOnly('2026-11-24')),
      'prep': caseOf('prep', CaseState.preparing, start: seoul('2026-11-25', '09:00')),
    }, now: today);
    expect(items[DateTime(2026, 11, 23)], isNull); // 어제 시작은 줄·마름모 없음
    expect([for (final i in items[DateTime(2026, 11, 24)]!) (i.notice.noticeId, i.start)], [('todayStart', true)]);
    expect([for (final i in items[DateTime(2026, 11, 25)]!) (i.notice.noticeId, i.start)], [('prep', true)]);
    // 지난 시작 공고도 마감 줄은 그대로
    expect(items[DateTime(2026, 11, 30)]!.map((i) => i.notice.noticeId), containsAll(['past', 'todayStart']));
  });

  test('지원 건 기록을 쓰지 않으면(저장소 없음) 예전처럼', () {
    final items = calendarItems(listOf([other]), [savedOf(prep), savedOf(applied)]);
    expect(items[DateTime(2026, 11, 27)]!.length, 3);
    expect(items[DateTime(2026, 11, 25)], isNull);
  });

  test('날짜 머리: 신청 시작뿐이면 "신청 시작", 섞이면 날짜만, 마감만·빈 날은 "마감"', () {
    final items = calendarItems(listOf([other]), [savedOf(prep), savedOf(applied)], cases: cases(), now: today);
    final d25 = DateTime(2026, 11, 25);
    final d27 = DateTime(2026, 11, 27);
    expect(dayTitle(d25, items[d25]!), '11월 25일(수) 신청 시작');
    expect(dayTitle(d27, items[d27]!), '11월 27일(금) 마감');
    expect(dayTitle(d27, [...items[d27]!, ...items[d25]!]), '11월 27일(금)');
    expect(dayTitle(d25, const []), '11월 25일(수) 마감');
  });

  testWidgets('줄은 남은 날 문구와 상태 칩, 신청 시작일은 마감 점 대신 마름모 표시', (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = ApplicationCaseStore(storage: MemoryCaseStorage(cases()), now: () => today);
    await store.load();
    final repo = CaseTrackingRepository(
      FakeCaseRepository(recommendations: [rec(other)], saved: [savedOf(prep), savedOf(applied)]),
      store,
    );
    await tester.pumpWidget(
      ApplicationCaseScope(
        notifier: store,
        child: MaterialApp(
          theme: gwittimTheme(),
          home: Scaffold(body: CalendarScreen(repository: repo, openUrl: (_) async => true, today: today)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 범례에 신청 시작(마름모)
    expect(findText('신청 시작'), findsOneWidget);
    expect(find.byKey(const ValueKey('mark-start')), findsNWidgets(2)); // 범례 + 11/25 칸
    // 위쪽 건수는 마감 줄만 센다(11/27 준비 중·신청함·맞춤 3건, 11/25 신청 시작은 빼고)
    expect(findText('11월 마감 3건'), findsOneWidget);
    // 11/25: 신청 시작 줄만 있어 마감 점은 없고 마름모만
    final start = find.byKey(const ValueKey('day-11-25'));
    expect(find.descendant(of: start, matching: find.byKey(const ValueKey('dot-saved'))), findsNothing);
    expect(find.descendant(of: start, matching: find.byKey(const ValueKey('mark-start'))), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('11월 25일 .*신청 시작 1건')), findsOneWidget);
    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(findText('11월 25일(수) 신청 시작'), findsOneWidget);
    expect(findText('1건'), findsOneWidget);
    expect(findText('신청 시작 · 09:00 · 공모전'), findsOneWidget);
    expect(find.widgetWithText(Pill, '신청 시작'), findsOneWidget);

    final deadline = find.byKey(const ValueKey('day-11-27'));
    expect(find.descendant(of: deadline, matching: find.byKey(const ValueKey('dot-saved'))), findsOneWidget);
    expect(find.descendant(of: deadline, matching: find.byKey(const ValueKey('dot-related'))), findsOneWidget);
    expect(find.descendant(of: deadline, matching: find.byKey(const ValueKey('mark-start'))), findsNothing);
    await tester.tap(deadline);
    await tester.pumpAndSettle();
    expect(findText('11월 27일(금) 마감'), findsOneWidget);
    expect(findText('D-3 · 11월 27일 마감 · 공모전'), findsNWidgets(2)); // 준비 중·신청함 줄(남은 날 문구)
    // 분류 이름은 단어 중간에서 끊기지 않게 한 덩어리
    expect(
      find.byWidgetPredicate((w) => w is Text && (w.textSpan?.toPlainText() ?? '').contains(' · ${keepTogether('공모전')}')),
      findsNWidgets(3), // 준비 중·신청함·맞춤 공고 줄
    );
    expect(find.widgetWithText(Pill, '준비 중'), findsOneWidget);
    expect(find.widgetWithText(Pill, '신청함'), findsOneWidget);
    expect(findText('가 맞춤 공고'), findsOneWidget);

    // 상태를 바꾸면 다시 받지 않아도 바로 바뀐다
    await store.markSkipped('prep');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(Pill, '준비 중'), findsNothing);
  });
}
