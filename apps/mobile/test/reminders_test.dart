// 기기 마감 알림 (report-reminder-spec §5.2): 가짜 시계·가짜 알림기
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/application_case.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/reminders.dart';

import 'case_fakes.dart';

class FakeNotifier implements ReminderNotifier {
  bool allowed = true;
  bool grantOnRequest = true;
  int requests = 0;
  int replaces = 0;
  List<PlannedReminder> scheduled = [];
  final _taps = StreamController<String>.broadcast();

  @override
  Future<bool> notificationsAllowed() async => allowed;

  @override
  Future<bool> requestPermission() async {
    requests++;
    allowed = grantOnRequest;
    return allowed;
  }

  @override
  Future<void> replaceAll(List<PlannedReminder> plan) async {
    replaces++;
    scheduled = plan;
  }

  @override
  Stream<String> get taps => _taps.stream;

  @override
  Future<String?> launchPayload() async => null;
}

ReminderInput input(NoticeSummary n, {DateInfo? start, int? todo}) =>
    ReminderInput(notice: n, applicationStart: start, todoLeft: todo);

void main() {
  final now = DateTime(2026, 11, 27, 12);

  group('시점 표', () {
    test('신청 시작 당일 09:00', () {
      final n = summaryOf('a', title: '공모전 A');
      final plan = planReminders([input(n, start: dateOnly('2026-11-30'))], now);
      expect(plan, [
        PlannedReminder(at: DateTime(2026, 11, 30, 9), title: '공모전 A', body: '오늘 신청 시작', payload: 'a'),
      ]);
    });

    test('마감 2일 전 09:00 할 일 남음, 마감 당일 09:00 시각 있음·미상', () {
      final timed = summaryOf('a', title: 'A', deadline: seoul('2026-12-05', '18:00'));
      final plan = planReminders([input(timed, todo: 2)], now);
      expect(plan.map((p) => (p.at, p.body)), [
        (DateTime(2026, 12, 3, 9), '마감 2일 전 · 할 일 2개 남음'),
        (DateTime(2026, 12, 5, 9), '오늘 18:00 마감'),
      ]);
      final dateOnlyN = summaryOf('b', title: 'B', deadline: dateOnly('2026-12-05'));
      final p2 = planReminders([input(dateOnlyN)], now);
      expect(p2.map((p) => p.body), ['마감 2일 전', '오늘 마감 · 시각 미상']); // 시각을 지어내지 않음
    });

    test('마감 시각이 10:00 이전이면 전날 20:00', () {
      final n = summaryOf('a', title: 'A', deadline: seoul('2026-12-05', '09:30'));
      final plan = planReminders([input(n)], now);
      expect(plan.last.at, DateTime(2026, 12, 4, 20));
      expect(plan.last.body, '내일 09:30 마감');
      final ten = summaryOf('b', title: 'B', deadline: seoul('2026-12-05', '10:00'));
      expect(planReminders([input(ten)], now).last.at, DateTime(2026, 12, 5, 9));
    });

    test('이미 지난 시각, 지난 마감은 예약하지 않음', () {
      final n = summaryOf('a', deadline: seoul('2026-11-27', '10:00'));
      expect(planReminders([input(n)], now), isEmpty);
      final past = summaryOf('b', deadline: dateOnly('2026-11-20'));
      expect(planReminders([input(past, start: dateOnly('2026-11-21'))], now), isEmpty);
    });
  });

  test('같은 시각은 한 알림으로 묶고, 하루 최대 2번', () {
    final ns = [
      for (final i in ['a', 'b', 'c']) summaryOf(i, title: '공고 $i', deadline: seoul('2026-12-05', '18:00')),
      summaryOf('d', title: '공고 d', deadline: seoul('2026-12-05', '09:00')), // 전날 20:00
    ];
    final plan = planReminders([for (final n in ns) input(n)], now);
    expect(plan.where((p) => p.at.day == 5).single.title, '저장한 공고 3건 오늘 마감');
    expect(plan.where((p) => p.at.day == 3).single.title, '저장한 공고 4건 마감 2일 전');
    final perDay = <int, int>{};
    for (final p in plan) {
      perDay[p.at.day] = (perDay[p.at.day] ?? 0) + 1;
    }
    expect(perDay.values.every((v) => v <= 2), isTrue);
    // 종류가 섞이면 종류별 건수
    final mixed = planReminders([
      input(summaryOf('x', title: 'X', deadline: dateOnly('2026-12-05'))),
      input(summaryOf('y', title: 'Y'), start: dateOnly('2026-12-03')),
    ], now);
    expect(mixed.firstWhere((p) => p.at.day == 3).body, '오늘 신청 시작 1건 · 마감 2일 전 1건');
  });

  group('예약기', () {
    late FakeNotifier notifier;
    late ApplicationCaseStore store;
    late ReminderService service;
    late DateTime clock;
    final a = summaryOf('a', title: '공고 a', deadline: seoul('2026-12-05', '18:00'));

    setUp(() async {
      clock = now;
      notifier = FakeNotifier();
      store = ApplicationCaseStore(storage: MemoryCaseStorage({'a': caseOf('a', CaseState.saved)}), now: () => clock);
      await store.load();
      service = ReminderService(notifier: notifier, prefs: MemoryReminderPrefs(), clock: () => clock)..attach(store);
    });

    test('저장 목록을 받기 전에는 예약을 건드리지 않고, 받으면 예약', () async {
      await service.load();
      expect(notifier.replaces, 0);
      await service.onSavedList([savedOf(a)]);
      await service.idle;
      expect(notifier.scheduled.length, 2);
    });

    test('상태가 끝나면 취소, 되돌리면 다시 예약', () async {
      await service.onSavedList([savedOf(a)]);
      await store.markApplied('a');
      await service.idle;
      expect(notifier.scheduled, isEmpty);
      await store.undo('a');
      await service.idle;
      expect(notifier.scheduled.length, 2);
      await store.markSkipped('a');
      await service.idle;
      expect(notifier.scheduled, isEmpty);
    });

    test('마감이 지나거나 저장을 취소하면 취소', () async {
      await service.onSavedList([savedOf(a)]);
      clock = DateTime(2026, 12, 6);
      await service.sync();
      expect(notifier.scheduled, isEmpty);
      clock = now;
      await service.sync();
      expect(notifier.scheduled.length, 2);
      await store.forget('a');
      await service.idle;
      expect(notifier.scheduled, isEmpty);
    });

    test('마감 연장, 당김이면 목록을 새로 받을 때 다시 예약', () async {
      await service.onSavedList([savedOf(a)]);
      final moved = summaryOf('a', title: '공고 a', deadline: seoul('2026-12-10', '18:00'));
      await service.onSavedList([savedOf(moved)]);
      expect(notifier.scheduled.map((p) => p.at.day), [8, 10]);
      final earlier = summaryOf('a', title: '공고 a', deadline: seoul('2026-11-30', '18:00'));
      await service.onSavedList([savedOf(earlier)]);
      expect(notifier.scheduled.map((p) => p.at.day), [28, 30]);
    });

    test('남은 할 일이 바뀌면 문구도 다시', () async {
      await service.onSavedList([savedOf(a)]);
      await store.recordTodoLines('a', ['가', '나']);
      await service.idle;
      expect(notifier.scheduled.first.body, '마감 2일 전 · 할 일 2개 남음');
      await store.toggleTodo('a', '가');
      await service.idle;
      expect(notifier.scheduled.first.body, '마감 2일 전 · 할 일 1개 남음');
    });

    test('끔 설정이면 0건, 다시 켜면 예약', () async {
      await service.onSavedList([savedOf(a)]);
      await service.setEnabled(false);
      expect(notifier.scheduled, isEmpty);
      await store.markApplied('a');
      await store.undo('a');
      await service.idle;
      expect(notifier.scheduled, isEmpty);
      await service.setEnabled(true);
      expect(notifier.scheduled.length, 2);
    });

    test('권한이 없으면 0건', () async {
      notifier.allowed = false;
      await service.onSavedList([savedOf(a)]);
      expect(notifier.scheduled, isEmpty);
      expect(service.permissionDenied, isTrue);
      notifier.allowed = true; // 기기 설정에서 허용
      await service.sync();
      expect(notifier.scheduled.length, 2);
      expect(service.permissionDenied, isFalse);
    });

    test('권한은 처음 저장할 때 한 번만 묻고, 거부하면 앱 안 표시만', () async {
      notifier
        ..allowed = false
        ..grantOnRequest = false;
      service.savedLoader = () async => [savedOf(a)];
      await service.load(); // 앱 시작에서는 묻지 않음
      expect(notifier.requests, 0);
      await service.afterSave();
      await service.afterSave();
      expect(notifier.requests, 1);
      expect(notifier.scheduled, isEmpty);
      expect(service.permissionDenied, isTrue);
    });

    test('허용하면 첫 저장 직후 예약됨', () async {
      notifier.allowed = false;
      service.savedLoader = () async => [savedOf(a)];
      await service.afterSave();
      expect(notifier.requests, 1);
      expect(notifier.scheduled.length, 2);
    });

    test('같은 계획이면 다시 예약하지 않음', () async {
      await service.onSavedList([savedOf(a)]);
      final n = notifier.replaces;
      await service.sync();
      await service.sync();
      expect(notifier.replaces, n);
    });
  });
}
