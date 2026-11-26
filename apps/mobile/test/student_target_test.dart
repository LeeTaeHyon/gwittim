// 지원 대상 문구 보강 (D-057, docs/student-target-extraction-spec.md §4·§6.1)
// '지원 대상: 대학생'만 있는 공고에서 휴학생 프로필은 학적 줄이 '직접 확인'이고, 포함 여부가 명시되지 않았다고 안내한다.
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/ui/report_screen.dart';

import 'finders.dart';
import 'report_verdict_test.dart' show pumpReport, reportNotice, rec, verdict;

const _unconfirmed = ConditionResult(
  field: 'enrollment_status',
  status: 'unknown',
  evidence: '지원 대상: 대학생',
  unknownReason: 'value_unconfirmed',
);

void main() {
  final notice = reportNotice(
    conditions: const [EligibilityCondition(field: 'enrollment_status', evidence: '지원 대상: 대학생')],
  );
  final recommendation = rec('needs_check', results: const [_unconfirmed]);

  test('휴학 프로필: 휴학생 포함 여부가 명시되지 않았다고 안내하고 프로필 입력을 권하지 않는다', () {
    final rows = checklistRows(notice, recommendation, (f) => f == 'enrollment_status' ? '휴학' : null);
    final row = rows.singleWhere((r) => r.state == CheckState.check);
    expect(row.label, '직접 확인');
    expect(row.note, '휴학생 포함 여부가 공고에 명시되지 않았습니다.');
    expect(rows.any((r) => (r.note ?? '').contains('프로필에 입력하면')), isFalse);
  });

  test('졸업 프로필 미확인은 다른 대상이 함께 나열된 경우라, 그 대상에 해당하는지 확인하라고 안내한다', () {
    // 예: '우리대학에 재직하고 있는 전임교원 및 재학 또는 휴학 중에 있는 학생'. 공고가 대상을 명시했으므로 '명시되지 않았다'고 하지 않는다
    final rows = checklistRows(notice, recommendation, (f) => f == 'enrollment_status' ? '졸업' : null);
    final note = rows.singleWhere((r) => r.state == CheckState.check).note;
    expect(note, '졸업생은 함께 나열된 다른 대상에 해당하는지 원문에서 확인해 주세요.');
    expect(note, isNot(contains('명시되지 않았습니다')));
  });

  test('학적을 모르면 일반 안내', () {
    expect(unconfirmedNote(null), '공고의 지원 대상에 해당하는지 원문에서 확인해 주세요.');
    expect(unconfirmedNote('재학'), '재학생은 함께 나열된 다른 대상에 해당하는지 원문에서 확인해 주세요.');
  });

  testWidgets('결론 카드 확인 개수가 체크리스트와 같고 재입력 안내가 없다', (tester) async {
    await pumpReport(tester, notice, recommendation: recommendation);
    expect(verdict(tester).take(2), ['조건', startsWith('확인 필요 1개')]);
    expect(findTextContaining('원문에서 확인해 주세요'), findsWidgets);
    expect(findTextContaining('프로필에 입력하면'), findsNothing);
  });
}
