import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/ui/format.dart';

DateInfo info(String date, {String? time, String? tz}) =>
    DateInfo(date: date, time: time, timezone: tz, precision: time == null ? 'date' : 'minute', evidence: '근거');

NoticeSummary summary({DateInfo? deadline, String? note, String status = 'open'}) => NoticeSummary(
  noticeId: 'n',
  noticeVersion: 1,
  title: 't',
  category: 'contest',
  sourceUrl: 'https://example.invalid',
  published: null,
  applicationDeadline: deadline,
  deadlineNote: note,
  lifecycleStatus: status,
);

void main() {
  test('날짜만 확인된 값은 시각을 보여주지 않는다', () {
    expect(formatDateInfo(info('2026-11-02')), '2026년 11월 2일 (월)');
  });

  test('시각이 확인되면 시각을 보여준다', () {
    expect(formatDateInfo(info('2026-10-18', time: '10:00', tz: 'Asia/Seoul')), '2026년 10월 18일 (일) 10:00');
  });

  test('시간대가 미상이면 그 사실을 함께 보여준다', () {
    expect(formatDateInfo(info('2026-10-18', time: '10:00')), '2026년 10월 18일 (일) 10:00 (시간대 미확인)');
  });

  test('마감 표시: 확정일 → 원문 설명 → 미상', () {
    expect(deadlineLabel(summary(deadline: info('2026-11-02'))), '마감 2026년 11월 2일 (월)');
    expect(deadlineLabel(summary(note: '선착순 마감')), '선착순 마감');
    expect(deadlineLabel(summary()), '마감일 미상');
  });

  test('남은 날짜는 모집 중이고 마감일이 있을 때만', () {
    final today = DateTime(2026, 10, 17, 23, 30);
    expect(daysLeftLabel(summary(deadline: info('2026-10-17')), today), '오늘 마감');
    expect(daysLeftLabel(summary(deadline: info('2026-11-02')), today), 'D-16');
    expect(daysLeftLabel(summary(deadline: info('2026-10-16')), today), isNull);
    expect(daysLeftLabel(summary(deadline: info('2026-11-02'), status: 'closed'), today), isNull);
    expect(daysLeftLabel(summary(note: '선착순'), today), isNull);
  });

  test('추천 이유는 관심 분야와 지원 조건을 구분한다', () {
    expect(reasonText('interest_match'), contains('관심 분야'));
    expect(reasonText('eligibility_met'), contains('지원 조건'));
    expect(reasonText('unknown_code'), '');
  });

  test('원문 확인이 24시간을 넘으면 오래된 정보 안내 (D-006)', () {
    final now = DateTime.utc(2026, 10, 18, 12);
    expect(staleNotice(DateTime.utc(2026, 10, 18, 3), now), isNull);
    expect(staleNotice(DateTime.utc(2026, 10, 17, 6), now), '마지막 확인 30시간 전이에요. 내용이 바뀌었을 수 있어요.');
    expect(staleNotice(DateTime.utc(2026, 10, 14, 12), now), '마지막 확인 4일 전이에요. 내용이 바뀌었을 수 있어요.');
    expect(staleNotice(null, now), contains('알 수 없어요'));
  });
}
