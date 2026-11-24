// 홈·브리핑: 끝난 지원 건 빼기, '신청 시작' 건수, 하루 1번 강조, 브리핑 카드 3개 (care-loop-impl-spec §7)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/application_case.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/ui/briefing_data.dart';
import 'package:gwittim/main.dart';
import 'package:gwittim/ui/home_sections.dart';
import 'package:gwittim/ui/components.dart';

import 'case_fakes.dart';
import 'finders.dart';

final today = DateTime(2026, 11, 24, 12);

RecommendationEntry rel(NoticeSummary n, {String status = 'met'}) => RecommendationEntry(
  recommendation: Recommendation(noticeId: n.noticeId, score: 50, eligibilityStatus: status, reasonCodes: const ['interest_match']),
  notice: n,
);

RecommendationList listOf(List<NoticeSummary> ns) =>
    RecommendationList(mode: 'personalized', items: [for (final n in ns) rel(n)], generatedAt: today);

void main() {
  final dueNow = summaryOf('due', deadline: dateOnly('2026-11-24'));
  final appliedDue = summaryOf('appliedDue', deadline: dateOnly('2026-11-24'));
  final skippedWeek = summaryOf('skipped', deadline: dateOnly('2026-11-27'));
  final prepWeek = summaryOf('prep', deadline: dateOnly('2026-11-27'));
  final startsNow = summaryOf('start', deadline: dateOnly('2026-12-20'));
  final startsLater = summaryOf('later', deadline: dateOnly('2026-12-20'));

  Map<String, ApplicationCase> cases() => {
    'due': caseOf('due', CaseState.saved),
    'appliedDue': caseOf('appliedDue', CaseState.applied),
    'skipped': caseOf('skipped', CaseState.skipped),
    'prep': caseOf('prep', CaseState.preparing),
    'start': caseOf('start', CaseState.saved, start: seoul('2026-11-24', '09:00')),
    'later': caseOf('later', CaseState.preparing, start: dateOnly('2026-11-25')),
  };

  final saved = [for (final n in [dueNow, appliedDue, skippedWeek, prepWeek, startsNow, startsLater]) savedOf(n)];

  group('홈 계산', () {
    test('끝난 지원 건은 이번 주 마감 줄에서 빠짐(추천 목록에 있어도)', () {
      final home = buildHomeSections(listOf([appliedDue, skippedWeek, prepWeek]), saved, today, cases: cases());
      expect(home.deadlines.map((r) => r.id), ['due', 'prep']);
      expect(home.rowIds.contains('skipped'), isFalse);
      expect(home.rowIds.contains('appliedDue'), isFalse);
    });

    test('지원 건 줄에는 지원 건 문구가 붙음', () {
      final home = buildHomeSections(listOf([prepWeek]), saved, today, cases: cases());
      final prep = home.deadlines.firstWhere((r) => r.id == 'prep');
      expect(prep.view!.stateLabel, '준비 중');
      expect(prep.view!.remaining, 'D-3 · 11월 27일 마감');
    });

    test('말풍선: 오늘 마감은 끝난 지원 건 빼고, 신청 시작은 진행 중 지원 건 중 오늘 시작만', () {
      final home = buildHomeSections(listOf([appliedDue]), saved, today, cases: cases());
      expect(home.nudge!.dueToday, 1); // due만 (appliedDue는 신청함)
      expect(home.nudge!.startToday, 1); // start만 (later는 내일)
      expect(home.nudge!.caseIds, {'due', 'start'});
    });

    test('신청 시작은 저장한 공고만 셈(지원 건 기록이 없으면 0)', () {
      final home = buildHomeSections(listOf([]), saved, today);
      expect(home.nudge!.startToday, 0);
    });

    test('오늘 앞선 실행에서 이미 강조한 지원 건은 세지 않음', () {
      final home = buildHomeSections(
        listOf([]),
        saved,
        today,
        cases: cases(),
        emphasizedEarlier: (id) => id == 'due' || id == 'start',
      );
      expect(home.nudge, isNull);
    });

    test('리포트에서 이미 본 마감 변경은 변경 카드·건수에 없음', () {
      final changed = savedOf(prepWeek, sameSnapshot: false, snapshot: dateOnly('2026-11-20'));
      final unseen = buildHomeSections(listOf([]), [changed], today, cases: {'prep': caseOf('prep', CaseState.saved)});
      expect(unseen.nudge!.changed, 1);
      final seen = buildHomeSections(
        listOf([]),
        [changed],
        today,
        cases: {'prep': caseOf('prep', CaseState.saved, seenDeadline: '2026-11-27')},
      );
      expect(seen.nudge, isNull);
      expect(seen.deadlines.single.deadlineChanged, isFalse);
    });
  });

  group('지원 건 저장소의 하루 1번 강조', () {
    test('같은 실행에서는 계속 세고, 다음 실행부터는 그날 다시 세지 않음', () async {
      final storage = MemoryCaseStorage(cases());
      final a = ApplicationCaseStore(storage: storage, now: () => today);
      await a.load();
      await a.markEmphasized(['due'], today);
      expect(a.emphasizedEarlier('due', today), isFalse); // 같은 실행
      await a.flushed;
      final b = ApplicationCaseStore(storage: storage, now: () => today);
      await b.load();
      expect(b.emphasizedEarlier('due', today), isTrue); // 다음 실행, 같은 날
      expect(b.emphasizedEarlier('due', today.add(const Duration(days: 1))), isFalse); // 다음 날
    });
  });

  group('브리핑', () {
    test('저장 곧 마감은 끝난 지원 건을 빼고, 신청 시작 소식이 있음', () {
      final b = buildBriefing(listOf([]), saved, today, cases: cases());
      expect(b.savedSoon.map((s) => s.notice.noticeId), ['due']);
      expect(b.startToday.map((s) => s.notice.noticeId), ['start']);
      expect(b.isEmpty, isFalse);
    });

    test('지원 건 카드는 하루 최대 3개(마감 가까운 순)', () {
      final many = [
        for (var i = 0; i < 4; i++) savedOf(summaryOf('s$i', deadline: dateOnly('2026-11-2${4 + (i % 2)}'))),
        savedOf(startsNow),
      ];
      final b = buildBriefing(listOf([]), many, today, cases: {
        for (var i = 0; i < 4; i++) 's$i': caseOf('s$i', CaseState.saved),
        'start': caseOf('start', CaseState.saved, start: seoul('2026-11-24', '09:00')),
      });
      expect(b.savedSoon.length + b.startToday.length, maxCaseCards);
      expect(b.startToday, isEmpty);
    });

    test('말풍선에 신청 시작이 있으면 브리핑도 비어 있지 않음', () {
      final only = [savedOf(startsNow)];
      final c = {'start': caseOf('start', CaseState.saved, start: seoul('2026-11-24', '09:00'))};
      final home = buildHomeSections(listOf([]), only, today, cases: c);
      final b = buildBriefing(listOf([]), only, today, cases: c);
      expect(home.nudge!.startToday, 1);
      expect(b.isEmpty, isFalse);
    });

    test('지원 건 기록을 쓰지 않으면 예전과 같음', () {
      final b = buildBriefing(listOf([]), saved, today);
      expect(b.savedSoon.map((s) => s.notice.noticeId), ['due', 'appliedDue']);
      expect(b.startToday, isEmpty);
    });
  });

  testWidgets('홈 말풍선에 "신청 시작", 브리핑에 신청 시작 카드, 지원 건 줄에 상태 칩·다음 할 일', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = ApplicationCaseStore(storage: MemoryCaseStorage(cases()), now: () => today);
    final repo = FakeCaseRepository(recommendations: [rel(prepWeek)], saved: [savedOf(prepWeek), savedOf(startsNow)]);
    await tester.pumpWidget(
      GwittimApp(
        repository: repo,
        openUrl: (_) async => true,
        today: today,
        briefingStore: MemoryBriefingStore(alwaysShown: true),
        caseStore: store,
      ),
    );
    await tester.pumpAndSettle();
    expect(findTextContaining('신청 시작'), findsWidgets);
    expect(find.widgetWithText(Pill, '준비 중'), findsOneWidget);
    expect(findTextContaining('원문에서 신청 방법 확인'), findsOneWidget); // 추천 이유 대신 다음 할 일
    await tester.tap(find.bySemanticsLabel(RegExp('오늘의 귀띔')));
    await tester.pumpAndSettle();
    expect(findText('오늘 09:00 신청 시작'), findsOneWidget);
    expect(store.emphasizedOn('start', today), isTrue);
  });
}
