import 'package:flutter/material.dart';
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
    expect(reasonText('major_prior_match'), contains('학과 졸업생')); // D-020
  });

  test('원문 확인이 24시간을 넘으면 오래된 정보 안내 (D-006)', () {
    final now = DateTime.utc(2026, 10, 18, 12);
    expect(staleNotice(DateTime.utc(2026, 10, 18, 3), now), isNull);
    expect(staleNotice(DateTime.utc(2026, 10, 17, 6), now), '30시간 전에 마지막으로 확인했습니다. 이후 내용이 바뀌었을 수 있습니다.');
    expect(staleNotice(DateTime.utc(2026, 10, 14, 12), now), '4일 전에 마지막으로 확인했습니다. 이후 내용이 바뀌었을 수 있습니다.');
    expect(staleNotice(null, now), contains('알 수 없습니다'));
  });

  group('keepAll', () {
    const wj = '\u2060';
    const nbsp = '\u00A0';
    String plain(String s) => s.replaceAll(wj, '').replaceAll(nbsp, ' ');

    test('보이는 글자는 그대로다', () {
      const s = '자동으로 비교하지 못한 조건이 있습니다. 원문에서 확인해 주세요.\n둘째 줄';
      expect(plain(keepAll(s)), s);
      expect(keepAll(''), '');
      expect(keepAll('확인'), '확$wj인');
    });

    test('자모 조합·이모지는 갈라지지 않고, 영문·숫자끼리는 그대로 둔다', () {
      const nfd = '한글'; // '한글' 자모 분해형
      expect(keepAll(nfd), '한$wj글');
      expect(keepAll('확인👍🏽'), '확$wj인$wj👍🏽');
      expect(keepAll('https://a.kr/b?c=1'), 'https://a.kr/b?c=1');
      expect(keepAll('D-3'), 'D-3');
      expect(keepAll('2일까지'), '2$wj일$wj까$wj지');
    });

    test('짧은 끝 문장은 통째로, 아니면 끝 두 어절을 묶는다', () {
      expect(keepAll('조건이 있습니다. 원문에서 확인해 주세요.'), '조$wj건$wj이 있$wj습$wj니$wj다$wj. 원$wj문$wj에$wj서$nbsp확$wj인$wj해$nbsp주$wj세$wj요$wj.');
      expect(keepAll('공고에서 찾은 조건을 내 프로필과 비교했습니다.').split(' ').last, '프$wj로$wj필$wj과$nbsp비$wj교$wj했$wj습$wj니$wj다$wj.');
    });

    testWidgets('좁은 폭에서 어절 중간에서 줄이 바뀌지 않는다', (tester) async {
      const s = '자동으로 비교하지 못한 조건이 있습니다. 원문에서 확인해 주세요.';
      for (final width in [200.0, 260.0, 340.0, 420.0]) {
        final text = keepAll(s);
        final painter = TextPainter(
          text: TextSpan(text: text, style: const TextStyle(fontSize: 14)),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: width);
        for (final line in painter.computeLineMetrics().skip(1)) {
          final start = painter.getPositionForOffset(Offset(0, line.baseline - line.ascent + 1)).offset;
          expect(start == 0 || text[start - 1] == ' ', isTrue, reason: '$width: ${plain(text.substring(start))}');
        }
        painter.dispose();
      }
    });
  });
}

