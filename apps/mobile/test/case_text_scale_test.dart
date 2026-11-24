// 360 폭·큰 글자(앱 안 1.3배)에서 지원 건이 보이는 화면이 넘치지 않는가 (care-loop-impl-spec §9)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/application_case.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/main.dart';
import 'package:gwittim/ui/briefing_data.dart';
import 'package:gwittim/ui/components.dart';
import 'package:gwittim/ui/report_screen.dart';

import 'case_fakes.dart';
import 'finders.dart';

final today = DateTime(2026, 11, 24, 12);

final _vertical = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);

Future<void> scrollToEnd(WidgetTester tester, {bool up = false}) async {
  for (var i = 0; i < 40; i++) {
    final visible = _vertical.hitTestable();
    if (visible.evaluate().isEmpty) return;
    final position = tester.state<ScrollableState>(visible.first).position;
    if (up ? position.pixels <= position.minScrollExtent : position.pixels >= position.maxScrollExtent) return;
    await tester.drag(visible.first, Offset(0, up ? 400 : -400));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('360 폭·큰 글자: 브리핑, 홈·달력·저장함, 리포트 내 지원 카드, 상세 분석 머리가 넘치지 않는다', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 72, bottom: 72);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    void noOverflow(String where) => expect(tester.takeException(), isNull, reason: where);

    const long = '2026학년도 동계방학 글로벌 어학·회화 프로그램 참가자 모집 안내(사전테스트 필수)';
    final due = summaryOf('due', deadline: dateOnly('2026-11-24'), title: '오늘 마감 공고 $long');
    final prep = summaryOf('prep', deadline: seoul('2026-11-25', '10:00'), title: '준비 중 공고 $long');
    final start = summaryOf('start', deadline: dateOnly('2026-12-20'), title: '오늘 신청 시작 공고 $long');
    final applied = summaryOf('applied', deadline: dateOnly('2026-11-27'), title: '신청한 공고 $long');
    final missed = summaryOf('missed', deadline: dateOnly('2026-11-20'), title: '놓친 공고 $long');
    final store = ApplicationCaseStore(
      storage: MemoryCaseStorage({
        'due': caseOf('due', CaseState.saved, eligibility: 'needs_check'),
        'prep': caseOf('prep', CaseState.preparing, eligibility: 'needs_check', applyUrl: 'https://mpu.mjc.ac.kr'),
        'start': caseOf('start', CaseState.saved, start: seoul('2026-11-24', '09:00')),
        'applied': caseOf('applied', CaseState.applied),
        'missed': caseOf('missed', CaseState.preparing),
      }),
      now: () => today,
    );
    final repo = FakeCaseRepository(
      recommendations: [
        for (final n in [due, prep, applied])
          RecommendationEntry(
            recommendation: Recommendation(noticeId: n.noticeId, score: 50, eligibilityStatus: 'needs_check', reasonCodes: const ['interest_match']),
            notice: n,
          ),
      ],
      saved: [for (final n in [due, prep, start, applied, missed]) savedOf(n)],
      analysis: AnalysisResponse(
        noticeId: 'prep',
        report: const AnalysisReport(fit: '맞음: 가', eligibility: '확인 필요: 나', todo: '다를 봅니다.', skills: '라'),
        expiresAt: DateTime(2027),
        fromCache: true,
      ),
    );
    await tester.pumpWidget(
      GwittimApp(repository: repo, openUrl: (_) async => true, today: today, briefingStore: MemoryBriefingStore(), caseStore: store),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('브리핑 닫기'), findsOneWidget); // 하루 첫 실행이라 브리핑이 뜬다
    await scrollToEnd(tester);
    noOverflow('브리핑(저장 곧 마감·신청 시작)');
    await tester.tap(find.byTooltip('브리핑 닫기'));
    await tester.pumpAndSettle();

    for (final tab in ['오늘', '달력', '저장함']) {
      await tester.tap(find.descendant(of: find.byType(GwTabBar), matching: find.text(tab)));
      await tester.pumpAndSettle();
      await scrollToEnd(tester, up: true);
      await scrollToEnd(tester);
      noOverflow('$tab 탭');
    }
    // 달력: 진행 중·신청함·신청 시작 줄이 있는 날
    await tester.tap(find.descendant(of: find.byType(GwTabBar), matching: find.text('달력')));
    await tester.pumpAndSettle();
    await scrollToEnd(tester, up: true);
    for (final d in [24, 25, 27]) {
      await tester.tap(find.byKey(ValueKey('day-11-$d')));
      await tester.pumpAndSettle();
      await scrollToEnd(tester);
      noOverflow('달력 11/$d');
      await scrollToEnd(tester, up: true);
    }

    // 저장함에서 준비 중 공고 리포트(내 지원 카드, 버튼 3개)
    await tester.tap(find.descendant(of: find.byType(GwTabBar), matching: find.text('저장함')));
    await tester.pumpAndSettle();
    await scrollToEnd(tester, up: true);
    final title = findText(prep.title);
    await tester.scrollUntilVisible(title, 300, scrollable: _vertical.hitTestable().first);
    await tester.tap(title.hitTestable());
    await tester.pumpAndSettle();
    expect(find.byType(ReportScreen), findsOneWidget);
    expect(find.text('신청함'), findsOneWidget);
    noOverflow('리포트 내 지원 카드');
    await scrollToEnd(tester);
    noOverflow('리포트 끝까지');
    final analysis = findText('받은 분석 보기');
    await tester.ensureVisible(analysis);
    await tester.pumpAndSettle();
    await tester.tap(analysis);
    await tester.pumpAndSettle();
    noOverflow('상세 분석 머리');
  });
}
