// 지원 전 할 일 체크 (report-reminder-spec §5.1)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/application_case.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/ui/agent_flow.dart';
import 'package:gwittim/ui/case_view.dart';
import 'package:gwittim/ui/theme.dart';

import 'case_fakes.dart';
import 'finders.dart';

final now = DateTime(2026, 11, 24, 12);
const todoText = '지원서 양식 내려받기\n포트폴리오 링크 준비\n재학증명서 발급';

AnalysisResponse response(String todo) => AnalysisResponse(
  noticeId: 'a',
  report: AnalysisReport(fit: '맞음: 관련 있음', eligibility: '충족: 재학', todo: todo, skills: 'SW 개발'),
  expiresAt: DateTime(2026, 12, 31),
  fromCache: false,
);

void main() {
  final a = summaryOf('a', deadline: seoul('2026-12-01', '10:00'));

  Future<(ApplicationCaseStore, FakeCaseRepository, MemoryCaseStorage)> pump(
    WidgetTester tester, {
    Map<String, ApplicationCase> cases = const {},
    String todo = todoText,
  }) async {
    final storage = MemoryCaseStorage(cases);
    final store = ApplicationCaseStore(storage: storage, now: () => now);
    await store.load();
    final repo = FakeCaseRepository(notices: {'a': noticeOf(a)});
    final tracked = CaseTrackingRepository(repo, store);
    await tester.pumpWidget(
      ApplicationCaseScope(
        notifier: store,
        child: MaterialApp(
          theme: gwittimTheme(),
          home: AnalysisReportScreen(response: response(todo), title: '공고 a', repository: tracked),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (store, repo, storage);
  }

  testWidgets('저장한 공고: 줄을 누르면 체크되고 저장 → 준비 중, 다시 누르면 해제', (tester) async {
    final (store, _, storage) = await pump(tester, cases: {'a': caseOf('a', CaseState.saved)});
    expect(store.todoRemaining('a'), 3);
    await tester.tap(findText('포트폴리오 링크 준비'));
    await tester.pumpAndSettle();
    expect(store.isTodoChecked('a', '포트폴리오 링크 준비'), isTrue);
    expect(store.todoRemaining('a'), 2);
    expect(store['a']!.state, CaseState.preparing);
    await store.flushed;
    expect(storage.savedTodos['a']!.checked, {'포트폴리오 링크 준비'});
    await tester.tap(findText('포트폴리오 링크 준비'));
    await tester.pumpAndSettle();
    expect(store.todoRemaining('a'), 3);
    expect(store['a']!.state, CaseState.preparing); // 해제해도 상태는 그대로
  });

  testWidgets('지원 건이 아니면 첫 체크에서 저장하고 준비 중으로', (tester) async {
    final (store, repo, _) = await pump(tester);
    expect(store['a'], isNull);
    await tester.tap(findText('재학증명서 발급'));
    await tester.pumpAndSettle();
    expect(repo.saved.map((e) => e.notice.noticeId), ['a']);
    expect(store['a']!.state, CaseState.preparing);
    expect(store.todoRemaining('a'), 2);
  });

  testWidgets('신청함·이번엔 안 함이면 체크만 하고 상태는 그대로', (tester) async {
    for (final s in [CaseState.applied, CaseState.skipped]) {
      final (store, _, _) = await pump(tester, cases: {'a': caseOf('a', s)});
      await tester.tap(findText('지원서 양식 내려받기'));
      await tester.pumpAndSettle();
      expect(store.isTodoChecked('a', '지원서 양식 내려받기'), isTrue);
      expect(store['a']!.state, s);
    }
  });

  testWidgets('고정 문장에는 체크 칸이 없음', (tester) async {
    final (store, _, _) = await pump(tester, cases: {'a': caseOf('a', CaseState.saved)}, todo: todoNone);
    expect(findText(todoNone), findsOneWidget);
    await tester.tap(findText(todoNone));
    await tester.pumpAndSettle();
    expect(store.todoRemaining('a'), isNull);
    expect(store['a']!.state, CaseState.saved);
    expect(find.byWidgetPredicate((w) => w is Semantics && w.properties.checked != null), findsNothing);
  });

  test('기기에 저장하고 다시 읽음, 줄이 바뀐 재분석은 같은 문장만 이어짐', () async {
    final storage = MemoryCaseStorage({'a': caseOf('a', CaseState.saved)});
    var store = ApplicationCaseStore(storage: storage, now: () => now);
    await store.load();
    await store.recordTodoLines('a', todoText.split('\n'));
    await store.toggleTodo('a', '지원서  양식 내려받기'); // 공백 정리
    await store.toggleTodo('a', '재학증명서 발급');
    await store.flushed;
    store = ApplicationCaseStore(storage: storage, now: () => now);
    await store.load();
    expect(store.isTodoChecked('a', '지원서 양식 내려받기'), isTrue);
    expect(store.todoRemaining('a'), 1);
    await store.recordTodoLines('a', ['지원서 양식 내려받기', '새 줄']);
    expect(store.isTodoChecked('a', '지원서 양식 내려받기'), isTrue);
    expect(store.isTodoChecked('a', '재학증명서 발급'), isFalse);
    expect(store.todoRemaining('a'), 1);
  });

  test('저장 취소하면 체크도 지워지고, 지원 건이 아니면 줄을 적지 않음', () async {
    final store = ApplicationCaseStore(storage: MemoryCaseStorage({'a': caseOf('a', CaseState.saved)}), now: () => now);
    await store.load();
    await store.recordTodoLines('a', ['줄 하나']);
    await store.recordTodoLines('b', ['남의 줄']);
    expect(store.todoRemaining('b'), isNull);
    await store.forget('a');
    expect(store.todoRemaining('a'), isNull);
  });

  test('남은 할 일 문구: 진행 중이고 남았을 때만', () async {
    final store = ApplicationCaseStore(storage: MemoryCaseStorage({'a': caseOf('a', CaseState.saved)}), now: () => now);
    await store.load();
    final view = caseView(a, store['a'], now: now);
    expect(todoLeftText(store, 'a', view), isNull); // 분석 안 받음
    await store.recordTodoLines('a', ['가', '나']);
    expect(todoLeftText(store, 'a', view), '남은 할 일 2개');
    await store.toggleTodo('a', '가');
    await store.toggleTodo('a', '나');
    expect(todoLeftText(store, 'a', view), isNull);
    await store.toggleTodo('a', '나');
    await store.markApplied('a');
    expect(todoLeftText(store, 'a', caseView(a, store['a'], now: now)), isNull); // 끝난 건
  });
}
