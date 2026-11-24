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

  test('지원 건 기록을 쓰지 않으면(저장소 없음) 예전처럼', () {
    final items = calendarItems(listOf([other]), [savedOf(prep), savedOf(applied)]);
    expect(items[DateTime(2026, 11, 27)]!.length, 3);
    expect(items[DateTime(2026, 11, 25)], isNull);
  });

  testWidgets('줄은 남은 날 문구와 상태 칩, 신청 시작 줄은 점을 더하지 않음', (tester) async {
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
    // 11/25: 신청 시작 줄만 있어 점이 없다
    final start = find.byKey(const ValueKey('day-11-25'));
    expect(find.descendant(of: start, matching: find.byKey(const ValueKey('dot-saved'))), findsNothing);
    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(findText('신청 시작 · 09:00 · 공모전'), findsOneWidget);
    expect(find.widgetWithText(Pill, '신청 시작'), findsOneWidget);

    final deadline = find.byKey(const ValueKey('day-11-27'));
    expect(find.descendant(of: deadline, matching: find.byKey(const ValueKey('dot-saved'))), findsOneWidget);
    expect(find.descendant(of: deadline, matching: find.byKey(const ValueKey('dot-related'))), findsOneWidget);
    await tester.tap(deadline);
    await tester.pumpAndSettle();
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
