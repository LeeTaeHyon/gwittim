import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/ui/agent_flow.dart';

void main() {
  test('줄바꿈으로 온 리포트는 줄마다 하나, 글머리 기호는 뗀다', () {
    expect(reportLines('맞음: 관심 분야와 겹침\n- 확인 필요: 근무지\n\n'), ['맞음: 관심 분야와 겹침', '확인 필요: 근무지']);
  });

  test('한 문단으로 온 긴 리포트는 문장 끝에서 나눈다 (예전 저장본)', () {
    const long = '공고의 구매 업무는 식자재 계약관리와 구매 운영입니다. 학생이 해 본 데이터 분석은 관련이 적지 않습니다. '
        '근무지가 서울인지는 공고 자료로 확인되지 않아 원문 확인이 필요합니다.';
    expect(reportLines(long), [
      '공고의 구매 업무는 식자재 계약관리와 구매 운영입니다.',
      '학생이 해 본 데이터 분석은 관련이 적지 않습니다.',
      '근무지가 서울인지는 공고 자료로 확인되지 않아 원문 확인이 필요합니다.',
    ]);
  });

  test('짧은 줄의 날짜 마침표는 나누지 않는다', () {
    expect(reportLines('확인 필요: 마감 2026. 11. 30. 이후 일정'), ['확인 필요: 마감 2026. 11. 30. 이후 일정']);
  });

  test('줄 앞 꼬리표를 떼어 낸다', () {
    expect(splitLineTag('맞음: 관심 분야와 겹침'), ('맞음', '관심 분야와 겹침'));
    expect(splitLineTag('안 맞음 : 시기가 다름'), ('안 맞음', '시기가 다름'));
    expect(splitLineTag('판정: 확인 필요'), ('판정', '확인 필요'));
    expect(splitLineTag('그냥 문장입니다.'), (null, '그냥 문장입니다.'));
  });
}
