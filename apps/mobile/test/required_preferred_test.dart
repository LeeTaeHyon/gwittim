// 필수 자격·우대 사항 구분 (D-056, docs/eligibility-required-preferred-spec.md §6.1·§7)
// 백엔드 테스트가 원문 → 규칙 추출 → 판정기로 만든 결과(골든 파일)를 그대로 넣어 체크리스트와 결론 카드 조건 줄을 확인한다.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/ui/report_screen.dart';

import 'finders.dart';
import 'report_verdict_test.dart' show pumpReport, reportNotice, rec, verdict;

const generic = '지원 자격을 모두 확인하지 못했습니다. 자세한 자격은 원문에서 확인해 주세요.';
const notFound = '공고에서 지원 조건을 찾지 못했습니다';
const notFoundOther = '그 밖의 지원 조건은 공고에서 찾지 못했습니다';

class Expect {
  const Expect(this.rows, this.status, this.condition, {this.generic = false});

  final List<String> rows;
  final String status;
  final String condition;

  /// 일반 안내 문장이 정확히 한 번 나오는지
  final bool generic;
}

// 줄 표기: 상태:이름[근거]. 줄 순서는 미충족 → 확인 필요 → 충족 → 안내
const expected = {
  'A1': Expect(['info:제한 없음[학년 무관]', 'info:$notFoundOther[]'], 'needs_check', '지원 조건 확인 필요'),
  'A2': Expect(['info:제한 없음[학년 무관]', 'info:$notFoundOther[]'], 'needs_check', '지원 조건 확인 필요'),
  'A3': Expect(
    ['info:제한 없음[학년 제한 없음]', 'info:우대 사항[관련 전공 우대]', 'info:$notFoundOther[]'],
    'needs_check',
    '지원 조건 확인 필요',
  ),
  'A4': Expect(['met:충족[재학생 대상, 학년 무관]', 'info:제한 없음[학년 무관]'], 'met', '조건 충족'),
  'A5': Expect(['met:누구나 지원 가능[누구나 지원 가능]', 'info:우대 사항[관련 전공 우대]'], 'met', '조건 충족'),
  'B1': Expect(['met:충족[재학생]', 'info:우대 사항[3~4학년 우대]'], 'met', '조건 충족'),
  'B2': Expect(['notMet:미충족[재학생]', 'info:우대 사항[3~4학년 우대]'], 'not_met', '조건 미충족'),
  'B3': Expect(['info:우대 사항[재학생(3~4학년 우대)]', 'info:$notFound[]'], 'needs_check', '지원 조건 확인 필요'),
  'B4': Expect(
    ['notMet:미충족[지원 자격: 3~4학년]', 'info:우대 사항[재학생(3~4학년 우대)]'],
    'not_met',
    '조건 미충족',
  ),
  'B5': Expect(['check:직접 확인[재학생(3~4학년 우대)]'], 'needs_check', '확인 필요 1개', generic: true),
  'C1': Expect(['met:충족[지원 대상: 재학생]', 'info:우대 사항[3~4학년]'], 'met', '조건 충족'),
  'C2': Expect(['notMet:미충족[지원 대상: 재학생]', 'info:우대 사항[3~4학년]'], 'not_met', '조건 미충족'),
  'C3': Expect(['check:직접 확인[3~4학년]'], 'needs_check', '확인 필요 1개', generic: true),
  'C4': Expect(['info:$notFound[]'], 'needs_check', '지원 조건 확인 필요'),
  'C5': Expect(['met:충족[- 재학생 대상]'], 'met', '조건 충족'),
  'C6': Expect(['met:충족[- 재학생 대상]'], 'met', '조건 충족'),
  'C7': Expect(['met:충족[본교 재학생 대상]', 'met:충족[본교 재학생 대상]'], 'needs_check', '지원 조건 확인 필요', generic: true),
  'C8': Expect(['met:충족[본교 재학생 대상]', 'met:충족[본교 재학생 대상]'], 'needs_check', '지원 조건 확인 필요', generic: true),
  'S13': Expect(
    ['check:직접 확인[학점 3.0 이상]', 'info:우대 사항[학점 3.0 이상]'],
    'needs_check',
    '확인 필요 1개',
    generic: true,
  ),
  'S15': Expect(['met:충족[지원 자격: 재학생]', 'info:우대 사항[3~4학년]'], 'needs_check', '지원 조건 확인 필요', generic: true),
  'S16': Expect(['check:직접 확인[평점 3.0 이상]', 'met:충족[지원 자격: 재학생]'], 'needs_check', '확인 필요 1개', generic: true),
  'S17': Expect(['check:직접 확인[평점 3.0 이상]', 'info:제한 없음[학년 무관]'], 'needs_check', '확인 필요 1개', generic: true),
};

String sig(CheckRow r) => '${r.state.name}:${r.label}[${r.evidences.join('|')}]';

void main() {
  final cases = (jsonDecode(File('test/data/required_preferred_cases.json').readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  test('골든 사례와 기대표가 같은 사례를 가리킨다', () {
    expect({for (final c in cases) c['id']}, expected.keys.toSet());
  });

  for (final c in cases) {
    final id = c['id'] as String;
    final want = expected[id]!;
    final notice = reportNotice();
    final withElig = Notice(
      summary: notice.summary,
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

    test('$id: 체크리스트 줄과 결론 카드 조건', () {
      expect(c['status'], want.status);
      final rows = checklistRows(withElig, recommendation, (_) => null);
      expect([for (final r in rows) sig(r)], want.rows);
      expect(verdictCondition(want.status, rows).$1, startsWith(want.condition));
    });

    testWidgets('$id: 화면 문구', (tester) async {
      await pumpReport(tester, withElig, recommendation: recommendation);
      expect(verdict(tester).take(2), ['조건', startsWith(want.condition)]);
      expect(findTextContaining(generic), want.generic ? findsOneWidget : findsNothing);
      expect(findTextContaining('0개'), findsNothing);
      expect(findTextContaining('첨부'), findsNothing);
      if (want.status == 'needs_check') expect(find.text('확인 필요'), findsWidgets);
    });
  }
}
