// 넘긴 공고의 행사일 표시: 일정 '행사', 마감 칸 '행사일 ○월 ○일', 지난 행사 (kakao-share-followup-spec §2)
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/ui/format.dart';

import 'finders.dart';
import 'report_verdict_test.dart' show pumpReport, reportNotice, verdict;

DateInfo _day(String date, {String? time}) => DateInfo(
  date: date,
  time: time,
  timezone: null,
  precision: time == null ? 'date' : 'minute',
  evidence: '일시: $date',
);

Notice _shared({DateInfo? deadline, DateInfo? start, DateInfo? end, String lifecycle = 'open', String source = 'user_share'}) {
  final base = reportNotice(deadline: deadline, lifecycle: lifecycle);
  return Notice(
    summary: base.summary,
    sourceId: source,
    description: null,
    applicationStart: null,
    activityPeriod: start == null ? null : ActivityPeriod(start: start, end: end, evidence: '일시'),
    eligibility: base.eligibility,
    lastVerifiedAt: null,
  );
}

void main() {
  // report_verdict_test의 today는 2026-10-17

  testWidgets('신청 마감이 없고 행사일만 있으면 마감 칸에 행사일, 일정에 행사', (tester) async {
    await pumpReport(tester, _shared(start: _day('2026-12-14')));
    expect(verdict(tester), contains('행사일 12월 14일'));
    expect(findText('12월 14일(월)'), findsOneWidget);
    expect(findText('행사'), findsOneWidget);
    expect(findText('활동 시작'), findsNothing);
  });

  testWidgets('신청 마감이 있으면 마감 칸은 그대로이고 일정에 행사도 보인다', (tester) async {
    await pumpReport(tester, _shared(deadline: _day('2026-11-27', time: '18:00'), start: _day('2026-12-14')));
    expect(verdict(tester).any((t) => t.contains('11월 27일 18:00 마감')), isTrue);
    expect(verdict(tester).any((t) => t.startsWith('행사일')), isFalse);
    expect(findText('행사'), findsOneWidget);
  });

  testWidgets('행사일이 지나 끝난 공고는 지난 행사', (tester) async {
    await pumpReport(tester, _shared(start: _day('2025-10-01'), lifecycle: 'closed'));
    expect(verdict(tester), contains('지난 행사'));
    expect(findText('지난 행사'), findsWidgets);
    expect(findText('마감'), findsOneWidget); // 이름표만
  });

  testWidgets('공용 공고는 그대로: 활동 시작·끝, 마감일 미상', (tester) async {
    await pumpReport(tester, _shared(start: _day('2026-12-14'), end: _day('2026-12-15'), source: 'mjc_www_notice'));
    expect(findText('활동 시작'), findsOneWidget);
    expect(findText('활동 끝'), findsOneWidget);
    expect(verdict(tester), contains('마감일 미상'));
  });

  testWidgets('넘긴 공고의 기간 행사는 시작·끝으로 보인다', (tester) async {
    await pumpReport(tester, _shared(start: _day('2026-12-14'), end: _day('2026-12-15')));
    expect(findText('행사 시작'), findsOneWidget);
    expect(findText('행사 끝'), findsOneWidget);
  });

  test('행사일 도우미', () {
    expect(sharedEventDay(_shared()), isNull);
    expect(sharedEventDay(_shared(start: _day('2026-12-14')))!.date, '2026-12-14');
    expect(sharedEventDay(_shared(start: _day('2026-12-14'), source: 'mjc_kakao')), isNull);
    expect(isPastSharedEvent(_shared(start: _day('2025-10-01'), lifecycle: 'closed')), isTrue);
    expect(isPastSharedEvent(_shared(deadline: _day('2025-10-01'), start: _day('2025-10-02'), lifecycle: 'closed')), isFalse);
  });
}
