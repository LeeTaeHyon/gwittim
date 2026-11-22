// 상세 분석 리포트 화면: 설명용 예시 두 개(실제 모델 출력 아님)로 첫 카드·순서·꼬리표·역량 표시를 확인한다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/ui/agent_flow.dart';
import 'package:gwittim/ui/theme.dart';

import 'finders.dart';

/// 예시 A (설명용): 경험은 맞지만 대면 장소 확인이 필요한 학생, 서버 판정 확인 필요
const exampleNeedsPlace = AnalysisReport(
  fit: '맞음: 이번 공모전은 앱 시제품을 제출하므로, 앱 개발 경험을 시제품 제작에 활용할 수 있습니다.\n'
      '확인 필요: 본선 발표가 수원에서 대면으로 진행된다고 안내되어 있어, 이동과 일정을 확인해야 합니다.',
  eligibility: '확인 필요: 재학 조건은 충족하지만, 학과 조건이 공고에 \'관련 학과\'로만 적혀 있어 해당 여부가 불명확합니다.\n'
      '앱 출시 경험은 우대 사항이며 필수 자격이 아닙니다.',
  todo: '수원 대면 발표일과 수업 일정을 대조합니다.\n\'관련 학과\'에 컴퓨터공학과가 포함되는지 주최 측 문의처에 확인합니다.',
  skills: '앱 시제품 제작\n사용자 문제 정의\n발표 자료 작성',
);

/// 예시 B (설명용): 학년 조건 미충족 학생, 서버 판정 미충족.
/// 학년 조건은 지원 자격 칸에서만 말하고, 판단을 바꿀 확인 사항이 없으니 할 일은 '없음' 한 문장(지침 detail-2026-11-23.4).
const exampleGradeNotMet = AnalysisReport(
  fit: '맞음: 공고의 과업이 데이터 분석이라, 해 본 것(데이터 분석)과 같은 종류의 일입니다.',
  eligibility: '미충족: 3학년 이상만 지원할 수 있는데 프로필 학년은 2학년입니다.\n재학 상태 조건은 충족합니다.',
  todo: '이번 모집은 지원 전에 할 일이 없습니다.',
  skills: '제공된 공고 정보에서 요구 역량을 확인하기 어렵습니다.',
);

Future<void> _pump(WidgetTester tester, AnalysisReport report, {String? status}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: gwittimTheme(),
      home: AnalysisReportScreen(
        response: AnalysisResponse(noticeId: 'n1', report: report, expiresAt: DateTime(2026, 12, 31), fromCache: false),
        title: '합성 공고',
        eligibilityStatus: status,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

double _top(WidgetTester tester, String text) => tester.getTopLeft(findText(text)).dy;

void main() {
  testWidgets('예시 A: 첫 카드는 나와 이 공고, 꼬리표와 역량 칩', (tester) async {
    await _pump(tester, exampleNeedsPlace, status: 'needs_check');
    expect(findText('나와 이 공고'), findsOneWidget);
    expect(findText('나에게 맞는 점·안 맞는 점'), findsNothing);
    // 기본 순서
    expect(_top(tester, '나와 이 공고'), lessThan(_top(tester, '지원 자격')));
    expect(_top(tester, '지원 자격'), lessThan(_top(tester, '지원 전 할 일')));
    // 줄 앞 꼬리표는 따로 보이고 본문에는 남지 않는다
    expect(find.text('맞음'), findsOneWidget);
    expect(find.text('확인 필요'), findsNWidgets(2)); // 나와 이 공고 1, 지원 자격 1
    expect(findTextContaining('맞음:'), findsNothing);
    // 역량은 칩 (아래에 있어 스크롤)
    await tester.scrollUntilVisible(find.text('앱 시제품 제작'), 300);
    expect(find.text('앱 시제품 제작'), findsOneWidget);
  });

  testWidgets('예시 B: 서버 판정이 미충족이면 지원 자격이 맨 위, 역량 안내는 일반 문장', (tester) async {
    await _pump(tester, exampleGradeNotMet, status: 'not_met');
    expect(_top(tester, '지원 자격'), lessThan(_top(tester, '나와 이 공고')));
    expect(find.text('미충족'), findsOneWidget);
    expect(find.text('맞음'), findsOneWidget);
    // 학년 조건은 지원 자격 칸에서 한 번만
    expect(findTextContaining('3학년'), findsOneWidget);
    expect(findTextContaining('다음 학기'), findsNothing);
    await tester.scrollUntilVisible(findTextContaining('요구 역량을 확인하기 어렵습니다'), 300);
    expect(findTextContaining('요구 역량을 확인하기 어렵습니다'), findsOneWidget);
  });

  testWidgets('서버 판정값이 없으면 리포트 글에 미충족이 있어도 기본 순서', (tester) async {
    await _pump(tester, exampleGradeNotMet); // status 없음 (저장 목록·달력에서 들어온 경우)
    expect(_top(tester, '나와 이 공고'), lessThan(_top(tester, '지원 자격')));
  });

  testWidgets('예전 저장본의 판정: 불충족 줄도 미충족 꼬리표로', (tester) async {
    const old = AnalysisReport(fit: '맞음: 겹침', eligibility: '판정: 불충족\n학년 조건', todo: '확인합니다.', skills: 'SW 개발');
    await _pump(tester, old);
    expect(find.text('미충족'), findsOneWidget);
    expect(findTextContaining('불충족'), findsNothing);
  });

  testWidgets('역량이 한 줄이어도 칩으로', (tester) async {
    const one = AnalysisReport(
      fit: '맞음: 겹침',
      eligibility: '충족: 재학 조건을 충족합니다.',
      todo: '확인합니다.',
      skills: '데이터 분석',
    );
    await _pump(tester, one, status: 'met');
    await tester.scrollUntilVisible(find.text('데이터 분석'), 300);
    expect(find.ancestor(of: find.text('데이터 분석'), matching: find.byType(Wrap)), findsOneWidget);
  });

  testWidgets('역량 확인 어려움 안내는 한 줄이어도 칩이 아님', (tester) async {
    await _pump(tester, exampleGradeNotMet, status: 'not_met');
    final unknown = findTextContaining('요구 역량을 확인하기 어렵습니다');
    await tester.scrollUntilVisible(unknown, 300);
    expect(find.ancestor(of: unknown, matching: find.byType(Wrap)), findsNothing);
  });
}
