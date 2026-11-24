// 기준 4 안전장치: 가짜 시계로 (가) 끝난 뒤 리마인드 0 (나) 마감일 변경 반영 (다) 하루 상한 (라) 10:00 마감 (마) 날짜만 마감
// (care-loop-impl-spec §9). (다)는 case_home_test, (라)(마)의 문구는 case_view_test에도 있다.
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/application_case.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/ui/briefing_data.dart';
import 'package:gwittim/ui/case_view.dart';
import 'package:gwittim/ui/home_sections.dart';

import 'case_fakes.dart';

RecommendationList empty(DateTime now) => RecommendationList(mode: 'personalized', items: const [], generatedAt: now);

/// 리마인드 = 말풍선 건수(오늘 마감·신청 시작)와 브리핑 지원 건 카드(저장 곧 마감·신청 시작)
int reminders(List<SavedEntry> saved, Map<String, ApplicationCase> cases, DateTime now) {
  final home = buildHomeSections(empty(now), saved, now, cases: cases);
  final b = buildBriefing(empty(now), saved, now, cases: cases);
  return (home.nudge?.dueToday ?? 0) + (home.nudge?.startToday ?? 0) + b.savedSoon.length + b.startToday.length;
}

void main() {
  final day = DateTime(2026, 11, 30, 9);

  group('(가) 끝난 뒤 리마인드 0', () {
    final due = summaryOf('a', deadline: dateOnly('2026-11-30'));
    final start = seoul('2026-11-30', '08:00');

    test('저장·준비 중이면 리마인드가 있음(기준선)', () {
      expect(reminders([savedOf(due)], {'a': caseOf('a', CaseState.saved, start: start)}, day), greaterThan(0));
      expect(reminders([savedOf(due)], {'a': caseOf('a', CaseState.preparing, start: start)}, day), greaterThan(0));
    });

    for (final s in [CaseState.applied, CaseState.skipped]) {
      test('${s.name}이면 0', () {
        expect(reminders([savedOf(due)], {'a': caseOf('a', s, start: start)}, day), 0);
      });
    }

    test('마감 지남이면 0 (10:00 마감, 10:01)', () {
      final morning = summaryOf('a', deadline: seoul('2026-11-30', '10:00'));
      final c = {'a': caseOf('a', CaseState.saved)};
      final kst1001 = DateTime.utc(2026, 11, 30, 1, 1).toLocal();
      expect(reminders([savedOf(morning)], c, DateTime.utc(2026, 11, 30, 0, 59).toLocal()), greaterThan(0));
      expect(reminders([savedOf(morning)], c, kst1001), 0);
    });

    test('모집 끝남·삭제됨이면 0', () {
      for (final lifecycle in ['closed', 'removed']) {
        final n = summaryOf('a', deadline: dateOnly('2026-11-30'), lifecycle: lifecycle);
        expect(reminders([savedOf(n)], {'a': caseOf('a', CaseState.preparing, start: start)}, day), 0, reason: lifecycle);
      }
    });
  });

  group('(나) 마감일 변경 반영', () {
    test('늦춰지면 마감 지남에서 되살아나고, 새 마감 2일 전부터 리마인드', () {
      final c = {'a': caseOf('a', CaseState.preparing)};
      final old = summaryOf('a', deadline: dateOnly('2026-11-28'));
      expect(caseView(old, c['a'], now: day).stateLabel, '마감 지남');
      expect(reminders([savedOf(old)], c, day), 0);
      final extended = summaryOf('a', deadline: dateOnly('2026-12-05'), version: 2);
      expect(caseView(extended, c['a'], now: day).stateLabel, '준비 중');
      expect(reminders([savedOf(extended)], c, day), 0); // 아직 2일 전이 아님
      expect(reminders([savedOf(extended)], c, DateTime(2026, 12, 3, 9)), greaterThan(0)); // 2일 전부터
    });

    test('당겨지면 새 날짜로 다시 셈', () {
      final c = {'a': caseOf('a', CaseState.saved)};
      final far = summaryOf('a', deadline: dateOnly('2026-12-20'));
      expect(reminders([savedOf(far)], c, day), 0);
      final pulled = summaryOf('a', deadline: dateOnly('2026-12-01'), version: 2);
      expect(reminders([savedOf(pulled)], c, day), greaterThan(0));
    });

    test('마감이 null로 바뀌면 날짜 리마인드는 멈추고 지원 건은 남음', () {
      final c = {'a': caseOf('a', CaseState.preparing)};
      final none = summaryOf('a', version: 2);
      expect(reminders([savedOf(none)], c, day), 0);
      expect(caseView(none, c['a'], now: day).stateLabel, '준비 중');
      expect(caseView(none, c['a'], now: day).remaining, '마감일 미상');
    });
  });

  group('(다) 하루 상한', () {
    test('브리핑 지원 건 카드 최대 3개, 강조는 지원 건당 하루 1번', () {
      final many = [for (var i = 0; i < 5; i++) savedOf(summaryOf('s$i', deadline: dateOnly('2026-11-30')))];
      final c = {for (var i = 0; i < 5; i++) 's$i': caseOf('s$i', CaseState.saved)};
      final b = buildBriefing(empty(day), many, day, cases: c);
      expect(b.savedSoon.length, maxCaseCards);
      final again = buildHomeSections(empty(day), many, day, cases: c, emphasizedEarlier: (_) => true);
      expect(again.nudge, isNull);
    });
  });

  group('(라)(마) 마감 시각', () {
    test('10:00 마감은 당일 10:01에 마감 지남, 그 전엔 오늘 10:00 마감', () {
      final n = summaryOf('a', deadline: seoul('2026-11-30', '10:00'));
      final c = caseOf('a', CaseState.saved);
      expect(caseView(n, c, now: DateTime.utc(2026, 11, 30, 0, 59).toLocal()).remaining, '오늘 10:00 마감');
      expect(caseView(n, c, now: DateTime.utc(2026, 11, 30, 1, 1).toLocal()).remaining, '마감 지남');
      expect(caseView(n, c, now: DateTime.utc(2026, 11, 30, 1, 1).toLocal()).stateLabel, '마감 지남');
    }, skip: DateTime(2026, 11, 30).timeZoneOffset == const Duration(hours: 9) ? false : '기기 시간대가 한국이 아님');

    test('날짜만 마감은 당일 내내 오늘 마감 · 시각 미상, 다음 날 0시 마감 지남', () {
      final n = summaryOf('a', deadline: dateOnly('2026-11-30'));
      final c = caseOf('a', CaseState.saved);
      expect(caseView(n, c, now: DateTime(2026, 11, 30, 23, 59)).remaining, '오늘 마감 · 시각 미상');
      expect(caseView(n, c, now: DateTime(2026, 12, 1)).remaining, '마감 지남');
    });
  });
}
