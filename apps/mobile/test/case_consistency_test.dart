// 기준 2 화면 일관성: 같은 지원 건의 상태 이름·다음 할 일·남은 날이 홈·달력·저장함·리포트·상세 분석에서 같은가
// (care-loop-impl-spec §9). 규칙상 안 나오는 조합은 '안 나옴'이 규칙과 맞는지 본다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/application_case.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/main.dart';
import 'package:gwittim/ui/agent_flow.dart';
import 'package:gwittim/ui/briefing_data.dart';
import 'package:gwittim/ui/calendar_screen.dart';
import 'package:gwittim/ui/case_view.dart';
import 'package:gwittim/ui/home_screen.dart';
import 'package:gwittim/ui/home_sections.dart';
import 'package:gwittim/ui/report_screen.dart';
import 'package:gwittim/ui/saved_screen.dart';
import 'package:gwittim/ui/theme.dart';

import 'case_fakes.dart';

final today = DateTime(2026, 11, 24, 12); // 화요일

/// 보이는 글자(keepAll 문자 뺌)
String _plain(String s) => s.replaceAll('⁠', '').replaceAll(' ', ' ');

/// [title] 줄(가장 가까운 InkWell) 안의 글자 전부
List<String> rowTexts(WidgetTester tester, String title) {
  final titleFinder = find.byWidgetPredicate((w) => w is Text && _plain(w.data ?? w.textSpan?.toPlainText() ?? '') == title);
  expect(titleFinder, findsOneWidget, reason: title);
  final row = find.ancestor(of: titleFinder, matching: find.byType(InkWell)).first;
  return [
    for (final w in tester.widgetList<Text>(find.descendant(of: row, matching: find.byType(Text))))
      _plain(w.data ?? w.textSpan?.toPlainText() ?? ''),
  ];
}

class Combo {
  Combo(this.state, this.kind, this.summary, this.kase);

  final String state;
  final String kind;
  final NoticeSummary summary;
  final ApplicationCase kase;

  String get title => summary.title;
  CaseView get view => caseView(summary, kase, now: today);
}

/// 상태 7 × 마감 4(시각·시간대 / 시각만·시간대 없음 / 날짜만 / 없음) + 오전 10:00 마감(내일)
List<Combo> combos() {
  final out = <Combo>[];
  const userStates = {
    'saved': CaseState.saved,
    'preparing': CaseState.preparing,
    'applied': CaseState.applied,
    'skipped': CaseState.skipped,
  };
  // 진행 중 건이 같은 남은 날 문구를 갖지 않게 날짜를 상태마다 다르게 둔다(25~28일, 7일 안)
  const day = {'saved': 25, 'preparing': 26, 'applied': 27, 'skipped': 28};
  for (final (si, state) in ['saved', 'preparing', 'applied', 'skipped', 'missed', 'closed', 'removed'].indexed) {
    for (final kind in ['seoul', 'notz', 'date', 'none']) {
      final d = state == 'missed' ? 20 : (day[state] ?? 29);
      final date = '2026-11-${d.toString().padLeft(2, '0')}';
      final deadline = switch (kind) {
        'seoul' => seoul(date, '1${si % 8}:00'),
        'notz' => DateInfo(date: date, time: '1${si % 8}:30', timezone: null, precision: 'minute', evidence: '근거'),
        'date' => dateOnly(date),
        _ => null,
      };
      if (state == 'missed' && deadline == null) continue; // 마감 없는 건은 마감 지남이 될 수 없다
      final lifecycle = switch (state) {
        'closed' => 'closed',
        'removed' => 'removed',
        _ => 'open',
      };
      final id = '$state-$kind';
      final s = summaryOf(id, deadline: deadline, lifecycle: lifecycle, title: '공고 $id');
      out.add(Combo(state, kind, s, caseOf(id, userStates[state] ?? CaseState.preparing, eligibility: 'needs_check')));
    }
  }
  final morning = summaryOf('morning', deadline: seoul('2026-11-25', '10:00'), title: '공고 morning');
  out.add(Combo('preparing', 'morning', morning, caseOf('morning', CaseState.preparing, eligibility: 'needs_check')));
  return out;
}

Future<ApplicationCaseStore> store(List<Combo> cs) async {
  final s = ApplicationCaseStore(
    storage: MemoryCaseStorage({for (final c in cs) c.summary.noticeId: c.kase}),
    now: () => today,
  );
  await s.load();
  return s;
}

FakeCaseRepository repoOf(List<Combo> cs) => FakeCaseRepository(
  recommendations: [
    for (final c in cs)
      RecommendationEntry(
        recommendation: Recommendation(
          noticeId: c.summary.noticeId,
          score: 50,
          eligibilityStatus: 'needs_check',
          reasonCodes: const ['interest_match'],
        ),
        notice: c.summary,
      ),
  ],
  saved: [for (final c in cs) savedOf(c.summary)],
);

void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 9000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  final all = combos();
  bool ended(Combo c) => c.view.ended;

  test('표본: 7상태가 모두 들어 있고 끝난 상태 판정이 맞음', () {
    expect(all.map((c) => c.view.stateLabel).toSet(), {'저장', '준비 중', '신청함', '이번엔 안 함', '마감 지남', '모집 끝남', '학교 공지에서 삭제됨'});
    expect(all.where((c) => c.kind == 'morning').single.view.remaining, '내일 10:00 마감');
  });

  testWidgets('저장함: 모든 지원 건 줄의 상태 칩·다음 할 일·남은 날이 문구 함수와 같음', (tester) async {
    tall(tester);
    final s = await store(all);
    await tester.pumpWidget(
      ApplicationCaseScope(
        notifier: s,
        child: MaterialApp(
          theme: gwittimTheme(),
          home: Scaffold(
            body: SavedScreen(repository: CaseTrackingRepository(repoOf(all), s), openUrl: (_) async => true, today: today),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final c in all) {
      final texts = rowTexts(tester, c.title);
      final v = c.view;
      if (c.state == 'removed') {
        expect(texts, contains('학교 공지에서 삭제됨'), reason: c.title);
        continue;
      }
      expect(texts.any((t) => t.startsWith('${v.remaining} · ')), isTrue, reason: '${c.title} $texts');
      expect(texts, contains(v.stateLabel), reason: c.title);
      if (v.next != null) expect(texts, contains(v.next!.text), reason: c.title);
    }
  });

  testWidgets('리포트 카드와 상세 분석 머리: 모든 지원 건이 문구 함수와 같음', (tester) async {
    tall(tester);
    for (final c in all) {
      final s = await store([c]);
      final repo = repoOf([c])
        ..analysis = AnalysisResponse(
          noticeId: c.summary.noticeId,
          report: const AnalysisReport(fit: '맞음: 가', eligibility: '확인 필요: 나', todo: '다를 봅니다.', skills: '라'),
          expiresAt: DateTime(2027),
          fromCache: true,
        );
      await tester.pumpWidget(
        ApplicationCaseScope(
          notifier: s,
          child: MaterialApp(
            theme: gwittimTheme(),
            home: ReportScreen(
              repository: CaseTrackingRepository(repo, s),
              noticeId: c.summary.noticeId,
              openUrl: (_) async => true,
              today: today,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final v = c.view;
      final card = find.ancestor(of: find.text('내 지원'), matching: find.byType(Container)).first;
      final texts = [
        for (final w in tester.widgetList<Text>(find.descendant(of: card, matching: find.byType(Text))))
          _plain(w.data ?? w.textSpan?.toPlainText() ?? ''),
      ];
      expect(texts, contains(v.stateLabel), reason: c.title);
      expect(texts, contains(v.remaining), reason: c.title);
      if (v.next != null) {
        expect(texts, contains(v.next!.text), reason: c.title);
      } else {
        expect(v.items, isEmpty);
      }
      // 상세 분석 머리 한 줄
      final button = find.byWidgetPredicate((w) => w is Text && _plain(w.data ?? '') == '받은 분석 보기');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      final head = ['내 지원', v.stateLabel!, if (v.next != null) v.next!.text, v.remaining].join(' · ');
      expect(
        find.descendant(of: find.byType(AnalysisReportScreen), matching: find.byWidgetPredicate((w) => w is Text && _plain(w.data ?? '') == head)),
        findsOneWidget,
        reason: c.title,
      );
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('달력: 진행 중·신청함 건은 문구 함수와 같고, 끝난 건(안 함·마감 지남·모집 끝남·삭제됨)은 없음', (tester) async {
    tall(tester);
    final s = await store(all);
    await tester.pumpWidget(
      ApplicationCaseScope(
        notifier: s,
        child: MaterialApp(
          theme: gwittimTheme(),
          home: Scaffold(
            body: CalendarScreen(repository: CaseTrackingRepository(repoOf(all), s), openUrl: (_) async => true, today: today),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final d in [20, 25, 26, 27, 28, 29]) {
      await tester.tap(find.byKey(ValueKey('day-11-$d')));
      await tester.pumpAndSettle();
      for (final c in all.where((c) => c.summary.applicationDeadline?.day.day == d)) {
        final shown = find.byWidgetPredicate((w) => w is Text && _plain(w.data ?? '') == c.title);
        if (ended(c) && c.state != 'applied') {
          expect(shown, findsNothing, reason: c.title);
          continue;
        }
        final texts = rowTexts(tester, c.title);
        expect(texts.any((t) => t.startsWith('${c.view.remaining} · ')), isTrue, reason: '${c.title} $texts');
        expect(texts, contains(c.view.stateLabel), reason: c.title);
      }
    }
  });

  testWidgets('홈: 7일 안 진행 중 건은 문구 함수와 같고, 끝난 건은 줄에 없음', (tester) async {
    tall(tester);
    final s = await store(all);
    await tester.pumpWidget(
      GwittimApp(
        repository: repoOf(all),
        openUrl: (_) async => true,
        today: today,
        briefingStore: MemoryBriefingStore(alwaysShown: true),
        caseStore: s,
      ),
    );
    await tester.pumpAndSettle();
    final home = find.byType(HomeScreen);
    var checked = 0;
    for (final c in all) {
      final shown = find.descendant(of: home, matching: find.byWidgetPredicate((w) => w is Text && _plain(w.data ?? '') == c.title));
      if (ended(c) || c.summary.applicationDeadline == null) {
        // 끝난 건은 빠지고, 마감 없는 건은 마감 구역에 들어가지 않는다(새 공고·먼 공고 구역 조건은 따로)
        if (ended(c)) expect(shown, findsNothing, reason: c.title);
        continue;
      }
      if (shown.evaluate().isEmpty) continue; // 이번 주 마감은 앞의 5건만 보인다
      final row = find.ancestor(of: shown, matching: find.byType(InkWell)).first;
      final texts = [
        for (final w in tester.widgetList<Text>(find.descendant(of: row, matching: find.byType(Text))))
          _plain(w.data ?? w.textSpan?.toPlainText() ?? ''),
      ];
      final meta = texts.firstWhere((t) => t.contains(' · '), orElse: () => '');
      expect(meta.startsWith(c.view.remaining), isTrue, reason: '${c.title} $texts');
      expect(meta.endsWith(c.view.next!.text), isTrue, reason: '${c.title} $texts');
      expect(texts, contains(c.view.stateLabel), reason: c.title);
      checked++;
    }
    expect(checked, homeWeekRows); // 이번 주 마감 줄 5건을 모두 대조했다
  });
}
