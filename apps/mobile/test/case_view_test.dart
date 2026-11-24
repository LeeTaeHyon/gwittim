// 지원 건 문구 함수: 상태 이름·다음 할 일·남은 날, 가짜 시계 (care-loop-impl-spec §3)
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/application_case.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/ui/case_view.dart';

DateInfo dateOnly(String date) => DateInfo(date: date, time: null, timezone: null, precision: 'date', evidence: '근거 $date');

DateInfo seoul(String date, String time) =>
    DateInfo(date: date, time: time, timezone: 'Asia/Seoul', precision: 'minute', evidence: '근거 $date $time');

DateInfo noTz(String date, String time) =>
    DateInfo(date: date, time: time, timezone: null, precision: 'minute', evidence: '근거 $date $time');

NoticeSummary notice({DateInfo? deadline, String lifecycle = 'open', String? sourceUrl = 'https://example.com/n'}) =>
    NoticeSummary(
      noticeId: 'n',
      noticeVersion: 1,
      title: '공고',
      category: 'contest',
      sourceUrl: sourceUrl,
      published: null,
      applicationDeadline: deadline,
      deadlineNote: '선착순',
      lifecycleStatus: lifecycle,
    );

ApplicationCase kase(CaseState s, {String? eligibility, DateInfo? applicationStart, String? applyUrl}) => ApplicationCase(
  noticeId: 'n',
  state: s,
  changedAt: DateTime(2026, 11, 1),
  eligibilityStatus: eligibility,
  applicationStart: applicationStart,
  applyUrl: applyUrl,
  detailVersion: applicationStart == null && applyUrl == null ? null : 1,
);

/// 한국 시각 → 기기 시각과 상관없는 같은 순간. 날짜 비교는 기기 날짜를 쓰므로, 시험은 기기 시각 = 한국 시각으로 본다.
DateTime kst(int y, int m, int d, [int h = 0, int mi = 0]) => DateTime.utc(y, m, d, h, mi).subtract(const Duration(hours: 9)).toLocal();

void main() {
  // 기기 시간대가 한국이 아니면 날짜 경계가 달라 이 시험의 '오늘' 계산이 틀린다(보고에 적음)
  final koreaDevice = DateTime(2026, 11, 24).timeZoneOffset == const Duration(hours: 9);

  group('남은 날 문구', () {
    String r(DateInfo? d, DateTime now, {String lifecycle = 'open'}) =>
        remainingText(notice(deadline: d, lifecycle: lifecycle), now);

    test('시각·시간대 있음: 2일 이상은 D-N', () {
      expect(r(seoul('2026-12-01', '10:00'), kst(2026, 11, 28, 9)), 'D-3 · 12월 1일 10:00 마감');
    });

    test('시각·시간대 있음: 내일 12:00 전 마감은 "내일", 12:00 이후는 D-1', () {
      expect(r(seoul('2026-12-01', '10:00'), kst(2026, 11, 30, 20)), '내일 10:00 마감');
      expect(r(seoul('2026-12-01', '18:00'), kst(2026, 11, 30, 20)), 'D-1 · 12월 1일 18:00 마감');
    });

    test('10:00 마감: 당일 09:59 "오늘 10:00 마감" → 10:01 "마감 지남"', () {
      final d = seoul('2026-12-01', '10:00');
      expect(r(d, kst(2026, 12, 1, 9, 59)), '오늘 10:00 마감');
      expect(r(d, kst(2026, 12, 1, 10, 1)), '마감 지남');
    }, skip: koreaDevice ? false : '기기 시간대가 한국이 아님');

    test('시각 있음·시간대 null: 당일엔 "오늘 18:00 마감", 지남 판정은 날짜로', () {
      final d = noTz('2026-11-30', '18:00');
      expect(r(d, DateTime(2026, 11, 27, 9)), 'D-3 · 11월 30일 18:00 마감');
      expect(r(d, DateTime(2026, 11, 30, 23, 59)), '오늘 18:00 마감');
      expect(r(d, DateTime(2026, 12, 1)), '마감 지남');
    });

    test('시간대 null이면 내일 오전 마감도 "내일"이 아니라 D-1', () {
      expect(r(noTz('2026-12-01', '10:00'), DateTime(2026, 11, 30, 20)), 'D-1 · 12월 1일 10:00 마감');
    });

    test('날짜만: 당일 23:59까지 "오늘 마감 · 시각 미상", 다음 날 0시 "마감 지남"', () {
      final d = dateOnly('2026-11-30');
      expect(r(d, DateTime(2026, 11, 27)), 'D-3 · 11월 30일 마감');
      expect(r(d, DateTime(2026, 11, 29, 23)), 'D-1 · 11월 30일 마감');
      expect(r(d, DateTime(2026, 11, 30)), '오늘 마감 · 시각 미상');
      expect(r(d, DateTime(2026, 11, 30, 23, 59)), '오늘 마감 · 시각 미상');
      expect(r(d, DateTime(2026, 12, 1)), '마감 지남');
    });

    test('마감 없음(상태 미확인 포함)은 "마감일 미상"', () {
      expect(r(null, DateTime(2026, 11, 24)), '마감일 미상');
      expect(r(null, DateTime(2026, 11, 24), lifecycle: 'unknown'), '마감일 미상');
    });

    test('상태 미확인이어도 마감이 있으면 날짜 규칙', () {
      expect(r(dateOnly('2026-11-30'), DateTime(2026, 11, 27), lifecycle: 'unknown'), 'D-3 · 11월 30일 마감');
    });

    test('모집 끝남·삭제됨', () {
      expect(r(dateOnly('2026-12-30'), DateTime(2026, 11, 24), lifecycle: 'closed'), '모집 끝남');
      expect(r(dateOnly('2026-12-30'), DateTime(2026, 11, 24), lifecycle: 'removed'), '학교 공지에서 삭제됨');
    });
  });

  group('상태 이름과 끝난 상태', () {
    final now = DateTime(2026, 11, 24, 12);
    final open = notice(deadline: dateOnly('2026-12-10'));

    test('상태 이름', () {
      expect(caseView(open, kase(CaseState.saved), now: now).stateLabel, '저장');
      expect(caseView(open, kase(CaseState.preparing), now: now).stateLabel, '준비 중');
      expect(caseView(open, kase(CaseState.applied), now: now).stateLabel, '신청함');
      expect(caseView(open, kase(CaseState.skipped), now: now).stateLabel, '이번엔 안 함');
      expect(caseView(notice(deadline: dateOnly('2026-11-20')), kase(CaseState.saved), now: now).stateLabel, '마감 지남');
      expect(caseView(notice(deadline: dateOnly('2026-12-10'), lifecycle: 'closed'), kase(CaseState.saved), now: now).stateLabel, '모집 끝남');
      expect(caseView(notice(lifecycle: 'removed'), kase(CaseState.saved), now: now).stateLabel, '학교 공지에서 삭제됨');
    });

    test('끝난 상태는 다음 할 일·항목이 없음', () {
      for (final v in [
        caseView(open, kase(CaseState.applied), now: now),
        caseView(open, kase(CaseState.skipped), now: now),
        caseView(notice(deadline: dateOnly('2026-11-20')), kase(CaseState.preparing), now: now),
      ]) {
        expect(v.ended, isTrue);
        expect(v.next, isNull);
        expect(v.items, isEmpty);
      }
    });

    test('지원 건이 아니면 상태 이름이 없음', () {
      expect(caseView(open, null, now: now).stateLabel, isNull);
      expect(caseView(open, null, now: now).ended, isFalse);
    });
  });

  group('할 일 항목과 순서', () {
    final now = DateTime(2026, 11, 24, 12);
    final deadline = dateOnly('2026-12-10');

    List<String> texts(CaseView v) => [for (final i in v.items) i.text];

    test('신청 경로: 신청 사이트 → 원문 → 받은 알림톡', () {
      expect(caseView(notice(deadline: deadline), kase(CaseState.saved, applyUrl: 'https://mpu.mjc.ac.kr'), now: now).next,
          const CaseItem(text: '신청 사이트에서 신청', kind: '행동', url: 'https://mpu.mjc.ac.kr'));
      expect(caseView(notice(deadline: deadline), kase(CaseState.saved), now: now).next,
          const CaseItem(text: '원문에서 신청 방법 확인', kind: '행동', url: 'https://example.com/n'));
      expect(caseView(notice(deadline: deadline, sourceUrl: null), kase(CaseState.saved), now: now).next,
          const CaseItem(text: '받은 알림톡에서 신청 방법 확인', kind: '행동'));
    });

    test('마감 항목은 맨 뒤이고 다음 할 일로 고르지 않음, 마감 설명은 쓰지 않음', () {
      final v = caseView(notice(deadline: seoul('2026-12-01', '10:00')), kase(CaseState.saved), now: now);
      expect(texts(v), ['원문에서 신청 방법 확인', '12월 1일 10:00 마감']);
      expect(v.items.last.evidence, '근거 2026-12-01 10:00');
      expect(v.next!.text, '원문에서 신청 방법 확인');
      expect(texts(v).any((t) => t.contains('선착순')), isFalse);
    });

    test('신청 시작 전·후', () {
      final start = seoul('2026-11-30', '10:00');
      final before = caseView(notice(deadline: deadline), kase(CaseState.saved, applicationStart: start), now: kst(2026, 11, 30, 9, 59));
      expect(before.next, CaseItem(text: '11월 30일 10:00 신청 시작', kind: '확인', evidence: start.evidence));
      final after = caseView(notice(deadline: deadline), kase(CaseState.saved, applicationStart: start), now: kst(2026, 11, 30, 10));
      expect(texts(after).any((t) => t.contains('신청 시작')), isFalse);
      // 날짜만 시작은 그 날 0시부터 시작으로 본다
      final dayStart = dateOnly('2026-12-14');
      final later = notice(deadline: dateOnly('2027-01-04'));
      expect(caseView(later, kase(CaseState.saved, applicationStart: dayStart), now: DateTime(2026, 12, 13, 23)).next!.text,
          '12월 14일 신청 시작');
      expect(caseView(later, kase(CaseState.saved, applicationStart: dayStart), now: DateTime(2026, 12, 14)).next!.text,
          '원문에서 신청 방법 확인');
    }, skip: koreaDevice ? false : '기기 시간대가 한국이 아님');

    test('saved: 조건 확인이 신청 경로보다 먼저', () {
      final v = caseView(notice(deadline: deadline), kase(CaseState.saved, eligibility: 'needs_check'), now: now);
      expect(texts(v), ['지원 조건 직접 확인', '원문에서 신청 방법 확인', '12월 10일 마감']);
      expect(v.next!.text, '지원 조건 직접 확인');
    });

    test('preparing: 조건 확인은 숨기지 않고 신청 경로 다음', () {
      final v = caseView(notice(deadline: deadline), kase(CaseState.preparing, eligibility: 'needs_check'), now: now);
      expect(texts(v), ['원문에서 신청 방법 확인', '지원 조건 직접 확인', '12월 10일 마감']);
      expect(v.next!.text, '원문에서 신청 방법 확인');
    });

    test('판정이 null·met·not_met이면 조건 확인 항목 없음', () {
      for (final e in [null, 'met', 'not_met']) {
        final v = caseView(notice(deadline: deadline), kase(CaseState.saved, eligibility: e), now: now);
        expect(texts(v).contains('지원 조건 직접 확인'), isFalse, reason: '$e');
      }
    });

    test('신청 시작 전이면 신청 시작이 조건 확인보다 먼저', () {
      final v = caseView(notice(deadline: deadline), kase(CaseState.saved, eligibility: 'needs_check', applicationStart: dateOnly('2026-12-01')),
          now: DateTime(2026, 11, 24));
      expect(texts(v), ['12월 1일 신청 시작', '지원 조건 직접 확인', '원문에서 신청 방법 확인', '12월 10일 마감']);
    });

    test('마감 없는 공고는 마감 항목 없이 신청 경로만', () {
      final v = caseView(notice(), kase(CaseState.saved), now: now);
      expect(texts(v), ['원문에서 신청 방법 확인']);
      expect(v.remaining, '마감일 미상');
    });
  });
}
