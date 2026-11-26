// 지원 대상 문구 보강 (D-057, docs/student-target-extraction-spec.md §4·§6.1)
// 백엔드 테스트가 실제 공고 문장 → 규칙 추출 → 판정기로 만든 결과(test/data/student_target_cases.json)를 그대로 넣어
// 학적 줄의 상태와 안내 문구, 결론 카드 조건을 확인한다. 결과 파일 갱신은 backend/analysis/tests/test_student_target.py 참고.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/ui/format.dart' show conditionFieldLabel;
import 'package:gwittim/ui/report_screen.dart';

import 'finders.dart';
import 'report_verdict_test.dart' show pumpReport, reportNotice, rec, verdict;

const leaveNote = '휴학생 포함 여부가 공고에 명시되지 않았습니다.';
const otherNote = '졸업생은 함께 나열된 다른 대상에 해당하는지 원문에서 확인해 주세요.';
const statusName = {'enrolled': '재학', 'on_leave': '휴학', 'graduated': '졸업'};

/// (학적 줄 '상태:이름|안내', 결론 카드 조건 시작)
const expected = {
  // '응모대상: 대학생': 휴학생 포함 여부를 공고가 말하지 않음, 졸업생은 대학생이 아님
  'univ_only/enrolled': ('met:재학|', '조건 충족'),
  'univ_only/on_leave': ('check:직접 확인|$leaveNote', '확인 필요 1개'),
  'univ_only/graduated': ('notMet:미충족|', '조건 미충족'),
  // '우리대학에 재직하고 있는 전임교원 및 재학 또는 휴학 중에 있는 학생': 졸업생은 전임교원에 해당하는지 확인
  'staff_and_students/enrolled': ('met:재학|', '조건 충족'),
  'staff_and_students/on_leave': ('met:휴학|', '조건 충족'),
  'staff_and_students/graduated': ('check:직접 확인|$otherNote', '확인 필요 1개'),
  // '응모대상: 일반인, 대학생': 휴학생은 대학생 쪽에서 포함 여부 미명시, 졸업생은 일반인에 해당하는지 확인
  'general_univ/enrolled': ('met:재학|', '조건 충족'),
  'general_univ/on_leave': ('check:직접 확인|$leaveNote', '확인 필요 1개'),
  'general_univ/graduated': ('check:직접 확인|$otherNote', '확인 필요 1개'),
};

void main() {
  final cases = (jsonDecode(File('test/data/student_target_cases.json').readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  test('결과 파일과 기대표가 같은 사례를 가리킨다', () {
    expect({for (final c in cases) '${c['id']}/${c['enrollment_status']}'}, expected.keys.toSet());
  });

  for (final c in cases) {
    final key = '${c['id']}/${c['enrollment_status']}';
    final want = expected[key]!;
    final base = reportNotice();
    final notice = Notice(
      summary: base.summary,
      description: null,
      applicationStart: null,
      activityPeriod: null,
      eligibility: Eligibility.fromJson(c['eligibility'] as Map<String, dynamic>),
      lastVerifiedAt: null,
    );
    final recommendation = rec(
      c['status'] as String,
      results: [for (final r in c['results'] as List) ConditionResult.fromJson(r as Map<String, dynamic>)],
    );
    final status = statusName[c['enrollment_status']]!;
    List<CheckRow> rows() =>
        checklistRows(notice, recommendation, (f) => f == 'enrollment_status' ? status : null);

    test('$key: 학적 줄과 결론 카드 조건', () {
      final all = rows();
      final row = all.singleWhere((r) => r.field == conditionFieldLabel('enrollment_status'));
      expect('${row.state.name}:${row.label}|${row.note ?? ''}', want.$1);
      expect(verdictCondition(c['status'] as String, all).$1, startsWith(want.$2));
      // 프로필을 다시 입력하라는 안내는 하지 않는다. 공고가 대상을 명시한 경우 '명시되지 않았다'고 하지 않는다
      expect(all.any((r) => (r.note ?? '').contains('프로필에 입력하면')), isFalse);
      if (c['id'] == 'staff_and_students') {
        expect(all.any((r) => (r.note ?? '').contains('명시되지 않았습니다')), isFalse);
      }
    });

    testWidgets('$key: 화면의 결론 카드와 재입력 안내 없음', (tester) async {
      await pumpReport(tester, notice, recommendation: recommendation);
      expect(verdict(tester).take(2), ['조건', startsWith(want.$2)]);
      expect(findTextContaining('프로필에 입력하면'), findsNothing);
    });
  }
}
