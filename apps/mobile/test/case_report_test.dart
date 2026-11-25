// 공고 리포트 '내 지원' 카드와 상세 분석 머리 한 줄 (care-loop-impl-spec §4)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/application_case.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/ui/agent_flow.dart';
import 'package:gwittim/ui/case_view.dart';
import 'package:gwittim/ui/report_screen.dart';
import 'package:gwittim/ui/theme.dart';

import 'case_fakes.dart';
import 'finders.dart';

final today = DateTime(2026, 11, 24, 12);

Future<ApplicationCaseStore> pumpReport(
  WidgetTester tester, {
  required FakeCaseRepository repo,
  Map<String, ApplicationCase> cases = const {},
  String id = 'a',
  List<Uri>? opened,
}) async {
  final store = ApplicationCaseStore(storage: MemoryCaseStorage(cases), now: () => today);
  await store.load();
  final tracked = CaseTrackingRepository(repo, store);
  await tester.pumpWidget(
    ApplicationCaseScope(
      notifier: store,
      child: MaterialApp(
        theme: gwittimTheme(),
        home: ReportScreen(
          repository: tracked,
          noticeId: id,
          openUrl: (u) async {
            opened?.add(u);
            return true;
          },
          today: today,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

void main() {
  final a = summaryOf('a', deadline: seoul('2026-12-01', '10:00'));

  testWidgets('저장하지 않은 공고에는 카드가 없음', (tester) async {
    await pumpReport(tester, repo: FakeCaseRepository(notices: {'a': noticeOf(a)}));
    expect(find.text('내 지원'), findsNothing);
  });

  testWidgets('저장 → 준비 시작 → 원문 열기·신청함 → 되돌리기', (tester) async {
    final opened = <Uri>[];
    final store = await pumpReport(
      tester,
      repo: FakeCaseRepository(saved: [savedOf(a)]),
      cases: {'a': caseOf('a', CaseState.saved)},
      opened: opened,
    );
    expect(find.text('내 지원'), findsOneWidget);
    expect(find.text('저장'), findsWidgets);
    expect(findText('D-7 · 12월 1일 10:00 마감'), findsOneWidget);
    expect(findText('원문에서 신청 방법 확인'), findsOneWidget);
    expect(findText('12월 1일 10:00 마감'), findsNothing); // 머리 줄과 겹치던 마감 줄은 없음
    // 진행 단계: 세 단계 이름이 모두 보이고 지금은 '저장'
    expect(find.byWidgetPredicate((w) => w is Semantics && w.properties.label == '진행 1/3단계, 저장'), findsOneWidget);
    expect(find.text('준비 시작'), findsOneWidget);
    expect(find.text('이번엔 안 함'), findsOneWidget);

    await tester.tap(find.text('준비 시작'));
    await tester.pumpAndSettle();
    expect(store['a']!.state, CaseState.preparing);
    expect(find.text('준비 중'), findsOneWidget);
    expect(find.text('원문 열기'), findsOneWidget);

    await tester.tap(find.text('원문 열기'));
    await tester.pumpAndSettle();
    expect(opened.single.toString(), 'https://example.com/n');

    await tester.tap(find.widgetWithText(TextButton, '신청함'));
    await tester.pumpAndSettle();
    expect(store['a']!.state, CaseState.applied);
    expect(find.text('신청함으로 표시했습니다.'), findsOneWidget);
    expect(find.text('준비 시작'), findsNothing);

    await tester.tap(find.widgetWithText(SnackBarAction, '되돌리기'));
    await tester.pumpAndSettle();
    expect(store['a']!.state, CaseState.preparing);
  });

  testWidgets('준비 중이고 신청 사이트가 있으면 "신청 사이트 열기"', (tester) async {
    await pumpReport(
      tester,
      repo: FakeCaseRepository(saved: [savedOf(a)], notices: {'a': noticeOf(a, applyUrl: 'https://mpu.mjc.ac.kr')}),
      cases: {'a': caseOf('a', CaseState.preparing)},
    );
    // 리포트가 상세를 받으면서 지원 건에 신청 사이트가 복사된다
    expect(findText('신청 사이트에서 신청'), findsOneWidget);
    expect(find.text('신청 사이트 열기'), findsWidgets);
  });

  testWidgets('이번엔 안 함 → 카드의 되돌리기 버튼', (tester) async {
    final store = await pumpReport(
      tester,
      repo: FakeCaseRepository(saved: [savedOf(a)]),
      cases: {'a': caseOf('a', CaseState.saved)},
    );
    await tester.tap(find.text('이번엔 안 함'));
    await tester.pumpAndSettle();
    expect(store['a']!.state, CaseState.skipped);
    expect(find.text('이번엔 안 함'), findsWidgets); // 상태 칩
    ScaffoldMessenger.of(tester.element(find.byType(ReportScreen))).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    // 끝난 건은 진행 단계 없이 한 줄
    expect(find.byWidgetPredicate((w) => w is Semantics && (w.properties.label ?? '').startsWith('진행 ')), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, '되돌리기'));
    await tester.pumpAndSettle();
    expect(store['a']!.state, CaseState.saved);
  });

  group('원문 문구는 출처에 맞춤', () {
    test('학교 게시판·알림톡·출처 없음은 학교 공지, 교외·모르는 출처는 공고 원문', () {
      for (final id in ['mjc_www_notice', 'mjc_kakao', 'sewu_www_notice', null]) {
        expect(originName(id), '학교 공지', reason: '$id');
      }
      for (final id in ['wevity_contest', 'contestkorea_contest', 'unknown']) {
        expect(originName(id), '공고 원문', reason: id);
        expect(originName(id, object: true), '공고 원문을', reason: id);
      }
    });

    for (final (source, button, summary) in [
      ('wevity_contest', '원문에서 보기', '공고 원문을 바탕으로 정리'),
      ('mjc_www_notice', '학교 공지에서 보기', '학교 공지를 바탕으로 정리'),
    ]) {
      testWidgets('$source: 아래 버튼 "$button", 요약 "$summary"', (tester) async {
        await pumpReport(
          tester,
          repo: FakeCaseRepository(
            saved: [savedOf(a)],
            notices: {'a': noticeOf(a, sourceId: source, description: '요약 한 줄')},
          ),
          cases: {'a': caseOf('a', CaseState.saved)},
        );
        expect(find.text(button), findsOneWidget);
        expect(find.text(summary), findsOneWidget);
      });
    }
  });

  testWidgets('되돌리기 알림은 저절로 닫히고, 다음 동작 알림이 앞 알림 뒤에 밀리지 않음', (tester) async {
    await pumpReport(
      tester,
      repo: FakeCaseRepository(saved: [savedOf(a)]),
      cases: {'a': caseOf('a', CaseState.saved)},
    );
    await tester.tap(find.text('준비 시작'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '신청함'));
    await tester.pumpAndSettle();
    expect(find.text('신청함으로 표시했습니다.'), findsOneWidget);
    // 바로 되돌린 뒤 이번엔 안 함: 앞 알림 대신 새 알림이 곧바로 보인다
    await tester.tap(find.widgetWithText(SnackBarAction, '되돌리기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이번엔 안 함'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('이번엔 안 함으로 표시했습니다.'), findsOneWidget);
    expect(find.text('신청함으로 표시했습니다.'), findsNothing);
    // 10초 뒤에는 저절로 닫혀 있다
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('내 지원 카드 버튼은 상태와 상관없이 모두 높이 44', (tester) async {
    // 눈에 보이는 버튼 바탕(Material) 높이. 누르는 영역은 접근성 기준대로 48까지 넓혀진다
    double heightOf(String text) => tester
        .getSize(
          find.descendant(
            of: find.ancestor(of: find.text(text), matching: find.bySubtype<ButtonStyleButton>()).first,
            matching: find.byType(Material),
          ).first,
        )
        .height;
    final store = await pumpReport(
      tester,
      repo: FakeCaseRepository(saved: [savedOf(a)]),
      cases: {'a': caseOf('a', CaseState.saved)},
    );
    expect(heightOf('준비 시작'), 44);
    expect(heightOf('이번엔 안 함'), 44);
    await tester.tap(find.text('준비 시작'));
    await tester.pumpAndSettle();
    // 준비 중: 원문 열기(채움)·신청함(연한 바탕)·이번엔 안 함(글자)
    for (final t in ['원문 열기', '신청함', '이번엔 안 함']) {
      expect(heightOf(t), 44, reason: t);
    }
    await store.markSkipped('a');
    await tester.pumpAndSettle();
    expect(heightOf('되돌리기'), 44);
  });

  testWidgets('끝난 지원 건(마감 지남)은 버튼이 없음', (tester) async {
    final passed = summaryOf('a', deadline: dateOnly('2026-11-20'));
    await pumpReport(tester, repo: FakeCaseRepository(saved: [savedOf(passed)]), cases: {'a': caseOf('a', CaseState.preparing)});
    expect(findText('마감 지남'), findsWidgets);
    expect(find.text('준비 시작'), findsNothing);
    expect(find.text('신청함'), findsNothing);
    expect(find.text('되돌리기'), findsNothing);
  });

  testWidgets('마감 변경 배너는 처음 열 때 한 번만, 열면 본 마감을 기록', (tester) async {
    final changedEntry = savedOf(a, sameSnapshot: false, snapshot: dateOnly('2026-11-28'));
    final repo = FakeCaseRepository(saved: [changedEntry]);
    final store = await pumpReport(tester, repo: repo, cases: {'a': caseOf('a', CaseState.saved)});
    expect(find.textContaining('저장한 뒤'), findsOneWidget);
    expect(store['a']!.seenDeadline, '2026-12-01 10:00');

    // 다시 열면 이미 본 변경이라 배너가 없다
    await tester.pumpWidget(const SizedBox());
    final tracked = CaseTrackingRepository(repo, store);
    await tester.pumpWidget(
      ApplicationCaseScope(
        notifier: store,
        child: MaterialApp(
          theme: gwittimTheme(),
          home: ReportScreen(repository: tracked, noticeId: 'a', openUrl: (_) async => true, today: today),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('저장한 뒤'), findsNothing);
  });

  testWidgets('리포트에서 저장하면 카드가 생기고 저장 취소하면 사라짐', (tester) async {
    final repo = FakeCaseRepository(notices: {'a': noticeOf(a)});
    final store = await pumpReport(tester, repo: repo);
    await tester.tap(find.byTooltip('저장'));
    await tester.pumpAndSettle();
    expect(store['a']!.state, CaseState.saved);
    expect(find.text('내 지원'), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(ReportScreen))).removeCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('저장 취소'));
    await tester.pumpAndSettle();
    expect(store['a'], isNull);
    expect(find.text('내 지원'), findsNothing);
  });

  testWidgets('상세 분석 머리 한 줄은 리포트 카드와 같은 문구', (tester) async {
    final response = AnalysisResponse(
      noticeId: 'a',
      report: const AnalysisReport(fit: '맞음: 테스트', eligibility: '충족: 테스트', todo: '원문을 봅니다.', skills: '테스트'),
      expiresAt: DateTime(2026, 12, 31),
      fromCache: true,
    );
    final store = await pumpReport(
      tester,
      repo: FakeCaseRepository(saved: [savedOf(a)], analysis: response),
      cases: {'a': caseOf('a', CaseState.preparing, eligibility: 'needs_check')},
    );
    final v = caseView(a, store['a'], now: today);
    final expected = '내 지원 · 준비 중 · ${v.next!.text} · ${v.remaining}';
    await tester.scrollUntilVisible(findText('받은 분석 보기'), 200, scrollable: find.byType(Scrollable).first);
    // 결론 카드가 생겨 버튼이 화면 아래 끝에 걸칠 수 있어 가운데까지 끌어온다
    await tester.ensureVisible(findText('받은 분석 보기'));
    await tester.pumpAndSettle();
    await tester.tap(findText('받은 분석 보기'));
    await tester.pumpAndSettle();
    expect(find.byType(AnalysisReportScreen), findsOneWidget);
    expect(findText(expected), findsOneWidget);
  });
}
