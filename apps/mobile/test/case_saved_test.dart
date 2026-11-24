// 저장함: 지원 건 상태 칩·다음 할 일·남은 날, 끝난 지원 묶음, 마감 변경 한 번만 (care-loop-impl-spec §5)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/application_case.dart';
import 'package:gwittim/ui/saved_screen.dart';
import 'package:gwittim/ui/format.dart';
import 'package:gwittim/ui/theme.dart';

import 'case_fakes.dart';
import 'finders.dart';

final today = DateTime(2026, 11, 24, 12); // 화요일

Future<ApplicationCaseStore> pumpSaved(
  WidgetTester tester,
  FakeCaseRepository repo, {
  Map<String, ApplicationCase> cases = const {},
}) async {
  final store = ApplicationCaseStore(storage: MemoryCaseStorage(cases), now: () => today);
  await store.load();
  await tester.pumpWidget(
    ApplicationCaseScope(
      notifier: store,
      child: MaterialApp(
        theme: gwittimTheme(),
        home: Scaffold(
          body: SavedScreen(repository: CaseTrackingRepository(repo, store), openUrl: (_) async => true, today: today),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

void main() {
  final week = summaryOf('week', deadline: dateOnly('2026-11-27'), title: '이번 주 공고');
  final prep = summaryOf('prep', deadline: seoul('2026-12-01', '10:00'), title: '준비 중 공고');
  final applied = summaryOf('applied', deadline: dateOnly('2026-11-28'), title: '신청한 공고');
  final skipped = summaryOf('skipped', deadline: dateOnly('2026-12-20'), title: '안 하는 공고');
  final missed = summaryOf('missed', deadline: dateOnly('2026-11-20'), title: '놓친 공고');

  testWidgets('진행 중은 마감 묶음, 끝난 지원 건은 맨 아래 "끝난 지원"', (tester) async {
    final store = await pumpSaved(
      tester,
      FakeCaseRepository(saved: [savedOf(week), savedOf(prep), savedOf(applied), savedOf(skipped), savedOf(missed)]),
      cases: {
        'week': caseOf('week', CaseState.saved, eligibility: 'needs_check'),
        'prep': caseOf('prep', CaseState.preparing),
        'applied': caseOf('applied', CaseState.applied),
        'skipped': caseOf('skipped', CaseState.skipped),
        'missed': caseOf('missed', CaseState.saved),
      },
    );
    final groups = groupSaved(
      [savedOf(week), savedOf(prep), savedOf(applied), savedOf(skipped), savedOf(missed)],
      today,
      cases: {for (final c in store.all) c.noticeId: c},
    );
    expect([for (final (g, l) in groups) '${g.name}: ${[for (final e in l) e.notice.noticeId].join(',')}'], [
      'thisWeek: week',
      'nextWeek: prep',
      'past: missed,applied,skipped',
    ]);
    expect(find.text('끝난 지원'), findsOneWidget);
    expect(find.text('이번 주 마감'), findsOneWidget);
  });

  testWidgets('줄마다 상태 칩·다음 할 일·남은 날(모든 화면과 같은 문구)', (tester) async {
    await pumpSaved(
      tester,
      FakeCaseRepository(saved: [savedOf(week), savedOf(prep), savedOf(applied)]),
      cases: {
        'week': caseOf('week', CaseState.saved, eligibility: 'needs_check'),
        'prep': caseOf('prep', CaseState.preparing),
        'applied': caseOf('applied', CaseState.applied),
      },
    );
    expect(findText('D-3 · 11월 27일 마감 · 공모전'), findsOneWidget);
    expect(findText('지원 조건 직접 확인'), findsOneWidget); // saved + 확인 필요
    expect(findText('D-7 · 12월 1일 10:00 마감 · 공모전'), findsOneWidget);
    // 분류 이름은 단어 중간에서 끊기지 않게 한 덩어리(큰 글자에서 '인턴·현/장실습'처럼 끊기던 문제)
    expect(
      find.byWidgetPredicate((w) => w is Text && (w.textSpan?.toPlainText() ?? '').endsWith(' · ${keepTogether('공모전')}')),
      findsNWidgets(3),
    );
    expect(find.text('준비 중'), findsOneWidget);
    expect(findText('원문에서 신청 방법 확인'), findsOneWidget); // preparing의 다음 할 일
    expect(find.text('신청함'), findsOneWidget);
    expect(find.text('저장'), findsOneWidget);
  });

  testWidgets('기록이 없는 저장 공고(기능 전 저장)는 "저장"으로 기록을 만듦', (tester) async {
    final store = await pumpSaved(tester, FakeCaseRepository(saved: [savedOf(week)]));
    expect(store['week']!.state, CaseState.saved);
    expect(find.text('저장'), findsOneWidget);
  });

  testWidgets('마감 변경: 리포트에서 지금 마감을 본 뒤에는 표시하지 않음', (tester) async {
    final changed = savedOf(prep, sameSnapshot: false, snapshot: dateOnly('2026-11-28'));
    await pumpSaved(tester, FakeCaseRepository(saved: [changed]), cases: {'prep': caseOf('prep', CaseState.saved)});
    expect(find.text('마감일이 바뀐 공고 1개'), findsOneWidget);
    expect(find.text('마감일 바뀜'), findsOneWidget);

    await pumpSaved(
      tester,
      FakeCaseRepository(saved: [changed]),
      cases: {'prep': caseOf('prep', CaseState.saved, seenDeadline: '2026-12-01 10:00')},
    );
    expect(find.text('마감일이 바뀐 공고 1개'), findsNothing);
    expect(find.text('마감일 바뀜'), findsNothing);
  });

  testWidgets('저장함에서 저장 취소하면 지원 건 기록도 지움', (tester) async {
    final store = await pumpSaved(
      tester,
      FakeCaseRepository(saved: [savedOf(week)]),
      cases: {'week': caseOf('week', CaseState.preparing)},
    );
    await tester.tap(find.byTooltip('저장 취소'));
    await tester.pumpAndSettle();
    expect(store['week'], isNull);
  });
}
