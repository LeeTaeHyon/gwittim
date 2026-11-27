// 상세 분석 결과 형광펜 (report-reminder-spec §4) + 결론 카드 'OO님 기준'
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/application_case.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/ui/agent_flow.dart';
import 'package:gwittim/ui/components.dart';
import 'package:gwittim/ui/guest_scope.dart';
import 'package:gwittim/ui/report_marks.dart';
import 'package:gwittim/ui/report_screen.dart';
import 'package:gwittim/ui/theme.dart';

import 'case_fakes.dart';

List<String> marked(String text, {List<String> names = const []}) => [
  for (final r in reportMarkRanges(text, names: names)) text.substring(r.start, r.end),
];

void main() {
  group('칠할 조각 찾기', () {
    test('날짜·시각 표기', () {
      expect(marked('12월 7일 18시까지 접수합니다.'), ['12월 7일 18시']);
      expect(marked('2026년 11월 30일 마감'), ['2026년 11월 30일']);
      expect(marked('11.30 마감, D-3'), ['11.30', 'D-3']);
      expect(marked('오늘 18:00 마감'), ['18:00']);
    });

    test('학점 같은 소수는 날짜로 보지 않음', () {
      expect(marked('평점 3.5 학점 이상'), isEmpty);
    });

    test('고른 해 본 것 이름과 작은따옴표 인용(따옴표 안쪽)', () {
      expect(marked("맞음: 우대 조건 '정보처리기사 자격'에 앱 개발 경험이 이어집니다.", names: ['앱 개발']), ['정보처리기사 자격', '앱 개발']);
      expect(marked('앱 개발 경험이 있습니다.'), isEmpty); // 이름을 모르면 칠하지 않음
    });

    test('한 줄 최대 2곳, 앞에서부터', () {
      expect(marked('12월 1일부터 12월 5일까지, 12월 9일 발표'), ['12월 1일', '12월 5일']);
    });

    test('14자를 넘는 조각은 칠하지 않음', () {
      expect(marked("'가나다라마바사아자차카타파하하'"), isEmpty); // 15자
      expect(marked("'가나다라마바사아자차카타파하'"), ['가나다라마바사아자차카타파하']); // 14자
      expect(marked('2026년 11월 30일 18시 30분 마감'), isEmpty); // 19자
    });

    test('겹치면 앞의 것만', () {
      expect(marked("'12월 7일 접수'", names: ['12월']), ['12월 7일 접수']);
    });
  });

  Future<void> pump(WidgetTester tester, AnalysisReport r, {List<String> names = const []}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: gwittimTheme(),
        home: AnalysisReportScreen(
          response: AnalysisResponse(noticeId: 'n1', report: r, expiresAt: DateTime(2026, 12, 31), fromCache: false),
          experienceNames: names,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('결과 카드: 날짜·칩 이름·인용은 칠하고 꼬리표·역량 칩은 칠하지 않음', (tester) async {
    await pump(
      tester,
      const AnalysisReport(
        fit: "맞음: 우대 조건 '정보처리기사'에 앱 개발 경험이 이어집니다.",
        eligibility: '확인 필요: 12월 7일 18시까지 재학 여부 확인',
        todo: '12월 7일 18시 전에 지원서 제출',
        skills: '앱 개발',
      ),
      names: ['앱 개발'],
    );
    final marks = tester.widgetList<Marker>(find.byType(Marker)).map((m) => m.text).toList();
    expect(marks, ['정보처리기사', '앱 개발', '12월 7일 18시', '12월 7일 18시']);
    // 꼬리표('맞음')와 역량 칩('앱 개발' 칩)은 Marker가 아니다
    expect(find.text('맞음'), findsOneWidget);
    expect(find.descendant(of: find.byType(Marker), matching: find.text('맞음')), findsNothing);
  });

  testWidgets('결론 카드: 로그인 이름이 있으면 OO님 기준, 게스트면 없음', (tester) async {
    final a = summaryOf('a', deadline: seoul('2026-12-01', '10:00'));
    const rec = Recommendation(noticeId: 'a', score: 0.5, eligibilityStatus: 'needs_check', reasonCodes: []);
    Future<void> show({required bool guest, String? name}) async {
      final store = ApplicationCaseStore(storage: MemoryCaseStorage());
      await store.load();
      await tester.pumpWidget(
        ApplicationCaseScope(
          notifier: store,
          child: GuestScope(
            guest: guest,
            displayName: name,
            child: MaterialApp(
              theme: gwittimTheme(),
              home: ReportScreen(
                repository: CaseTrackingRepository(
                  FakeCaseRepository(
                    notices: {'a': noticeOf(a)},
                    recommendations: [
                      RecommendationEntry(
                        notice: a,
                        recommendation: rec,
                      ),
                    ],
                  ),
                  store,
                ),
                noticeId: 'a',
                openUrl: (_) async => true,
                today: DateTime(2026, 11, 24, 12),
                recommendation: rec,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show(guest: false, name: '김귀띔');
    expect(find.byKey(reportVerdictNameKey), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(reportVerdictNameKey)).data, '김귀띔님 기준');
    await show(guest: true, name: '김귀띔');
    expect(find.byKey(reportVerdictNameKey), findsNothing);
    await show(guest: false);
    expect(find.byKey(reportVerdictNameKey), findsNothing);
  });
}
