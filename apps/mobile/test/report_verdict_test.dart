// 리포트 결론 카드와 체크리스트 순서·충족 접기 (home-report-clarity-spec B1~B3)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/ui/report_screen.dart';
import 'package:gwittim/ui/theme.dart';

import 'app_test.dart' show OneNoticeRepository;
import 'finders.dart';

final today = DateTime(2026, 10, 17, 9);

const _tz = 'Asia/Seoul';

DateInfo _day(String date, {String? time}) => DateInfo(
  date: date,
  time: time,
  timezone: time == null ? null : _tz,
  precision: time == null ? 'date' : 'minute',
  evidence: date,
);

Notice reportNotice({
  DateInfo? deadline,
  String? note,
  String lifecycle = 'open',
  List<EligibilityCondition> conditions = const [],
  List<String> unresolved = const [],
  bool complete = true,
}) => Notice(
  summary: NoticeSummary(
    noticeId: 'n',
    noticeVersion: 1,
    title: '[합성 샘플] 결론 카드 확인 공고',
    category: 'contest',
    sourceUrl: 'https://example.invalid/n',
    published: null,
    applicationDeadline: deadline,
    deadlineNote: note,
    lifecycleStatus: lifecycle,
  ),
  description: null,
  applicationStart: null,
  activityPeriod: null,
  eligibility: Eligibility(
    conditions: conditions,
    unresolvedEvidence: unresolved,
    preferredEvidence: const [],
    extractionComplete: complete,
    explicitlyUnrestricted: false,
    unrestrictedEvidence: null,
  ),
  lastVerifiedAt: null,
);

Recommendation rec(String status, {List<ConditionResult> results = const [], List<String> reasons = const []}) =>
    Recommendation(
      noticeId: 'n',
      score: null,
      eligibilityStatus: status,
      reasonCodes: reasons,
      conditionResults: results,
    );

Future<void> pumpReport(WidgetTester tester, Notice notice, {Recommendation? recommendation}) async {
  tester.view.physicalSize = const Size(800, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    MaterialApp(
      theme: gwittimTheme(),
      home: ReportScreen(
        key: UniqueKey(),
        repository: OneNoticeRepository(notice),
        noticeId: 'n',
        openUrl: (_) async => true,
        today: today,
        recommendation: recommendation,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String _plain(Text w) => (w.data ?? w.textSpan?.toPlainText() ?? '').replaceAll('⁠', '').replaceAll(' ', ' ');

/// 결론 카드 안 글자를 위에서부터: [이름표, 값, 이름표, 값, ...]
List<String> verdict(WidgetTester tester) => [
  for (final t in tester.widgetList<Text>(find.descendant(of: find.byKey(reportVerdictKey), matching: find.byType(Text))))
    _plain(t),
];

Color verdictColor(WidgetTester tester, String value) =>
    tester.widget<Text>(find.descendant(of: find.byKey(reportVerdictKey), matching: findText(value))).style!.color!;

const _grade = ConditionResult(field: 'grade', status: 'unknown', evidence: '2~3학년', unknownReason: 'profile_missing');
const _majorMet = ConditionResult(field: 'major_id', status: 'met', evidence: '컴퓨터공학과');
const _uniMet = ConditionResult(field: 'university_id', status: 'met', evidence: '명지전문대');
const _gradeNotMet = ConditionResult(field: 'grade', status: 'not_met', evidence: '4학년');

void main() {
  final light = GwColors.light;

  group('결론 카드: 조건', () {
    testWidgets('met: 조건 충족(accent), 마감, 추천 이유 순서', (tester) async {
      await pumpReport(
        tester,
        reportNotice(deadline: _day('2026-10-30', time: '17:00')),
        recommendation: rec('met', results: const [_majorMet], reasons: const ['interest_match']),
      );
      expect(verdict(tester), ['조건', '조건 충족', '마감', '10월 30일 17:00 마감 · D-13', '추천', '관심 분야 관련']);
      expect(verdictColor(tester, '조건 충족'), light.accent);
      expect(verdictColor(tester, '10월 30일 17:00 마감 · D-13'), light.ink); // 7일보다 멀면 ink
      expect(verdictColor(tester, '관심 분야 관련'), light.accent);
    });

    testWidgets('not_met: 조건 미충족과 미충족 항목 이름(urgent)', (tester) async {
      await pumpReport(
        tester,
        reportNotice(deadline: _day('2026-10-20')),
        recommendation: rec('not_met', results: const [_majorMet, _gradeNotMet]),
      );
      expect(verdict(tester), ['조건', '조건 미충족 · 학년', '마감', '10월 20일 마감 · D-3']);
      expect(verdictColor(tester, '조건 미충족 · 학년'), light.urgent);
      expect(verdictColor(tester, '10월 20일 마감 · D-3'), light.urgent); // 7일 안
    });

    testWidgets('추천 정보 없이 연 공고는 조건 줄이 없다', (tester) async {
      await pumpReport(tester, reportNotice(deadline: _day('2026-10-30')));
      expect(verdict(tester), ['마감', '10월 30일 마감 · D-13']);
    });

    testWidgets('needs_check: 체크리스트 안내 문장과 같은 개수, 이름표 있는 항목 이름', (tester) async {
      await pumpReport(
        tester,
        reportNotice(deadline: _day('2026-10-30'), unresolved: ['자격증 소지자', '주말 근무 가능자']),
        recommendation: rec('needs_check', results: const [_majorMet, _grade], reasons: const ['major_match']),
      );
      expect(verdict(tester), ['조건', '확인 필요 3개 · 학년', '마감', '10월 30일 마감 · D-13', '추천', '전공 관련']);
      expect(findText('조건 1개 충족. 3개는 직접 확인해 주세요.'), findsOneWidget);
      expect(verdictColor(tester, '확인 필요 3개 · 학년'), light.check);
      // 화면 읽기는 카드 하나로
      final handle = tester.ensureSemantics();
      expect(tester.getSemantics(find.byKey(reportVerdictKey)).label, '조건 확인 필요 3개 학년, 10월 30일 마감 D-13, 전공 관련');
      handle.dispose();
    });

    testWidgets('needs_check인데 셀 수 있는 확인 항목이 0개면 지원 조건 확인 필요', (tester) async {
      await pumpReport(tester, reportNotice(deadline: _day('2026-10-30')), recommendation: rec('needs_check'));
      expect(verdict(tester), ['조건', '지원 조건 확인 필요', '마감', '10월 30일 마감 · D-13']);
      expect(findText('공고에서 지원 조건을 찾지 못했습니다'), findsOneWidget);
      // 비교한 조건이 없으니 '내 프로필과 비교했습니다'라고 쓰지 않는다
      expect(findText('자동으로 비교한 조건이 없습니다.'), findsOneWidget);
      expect(findTextContaining('비교했습니다'), findsNothing);
    });

    testWidgets('조건이 다 추출되지 않아도 조건 값 뒤에 덧붙이지 않고 체크리스트 아래 안내에 맡긴다', (tester) async {
      await pumpReport(
        tester,
        reportNotice(deadline: _day('2026-10-30'), complete: false),
        recommendation: rec('met', results: const [_majorMet]),
      );
      expect(verdict(tester).take(2), ['조건', '조건 충족']);
      expect(findTextContaining('첨부파일·이미지에 조건이 더 있을 수 있습니다'), findsOneWidget);
    });
  });

  group('결론 카드: 모집 상태와 마감', () {
    testWidgets('모집 상태 unknown이어도 조건 판정·확인된 마감·추천 이유를 보인다', (tester) async {
      await pumpReport(
        tester,
        reportNotice(deadline: _day('2026-10-30'), lifecycle: 'unknown'),
        recommendation: rec('met', results: const [_majorMet], reasons: const ['interest_match']),
      );
      expect(verdict(tester), ['조건', '조건 충족', '마감', '10월 30일 마감 · D-13', '추천', '관심 분야 관련']);
    });

    testWidgets('마감 날짜가 없으면 원문 설명, 설명도 없으면 마감일 미상(sub)', (tester) async {
      await pumpReport(tester, reportNotice(note: '예산 소진 시까지', lifecycle: 'unknown'), recommendation: rec('met'));
      expect(verdict(tester), ['조건', '조건 충족', '마감', '예산 소진 시까지']);
      expect(verdictColor(tester, '예산 소진 시까지'), light.ink);
      await pumpReport(tester, reportNotice(), recommendation: rec('met'));
      expect(verdict(tester), ['조건', '조건 충족', '마감', '마감일 미상']);
      expect(verdictColor(tester, '마감일 미상'), light.sub);
    });

    testWidgets('closed는 마감, removed는 삭제된 공고 한 줄만', (tester) async {
      final r = rec('met', results: const [_majorMet], reasons: const ['interest_match']);
      await pumpReport(tester, reportNotice(deadline: _day('2026-10-10'), lifecycle: 'closed'), recommendation: r);
      expect(verdict(tester), ['마감', '마감']);
      expect(tester.widget<Text>(find.descendant(of: find.byKey(reportVerdictKey), matching: findText('마감')).last).style!.color, light.sub);
      await pumpReport(tester, reportNotice(deadline: _day('2026-10-30'), lifecycle: 'removed'), recommendation: r);
      expect(verdict(tester), ['마감', '삭제된 공고']);
    });

    testWidgets('오늘 마감: 시각이 확인되면 오늘 17:00 마감, 날짜만이면 오늘 마감', (tester) async {
      await pumpReport(tester, reportNotice(deadline: _day('2026-10-17', time: '17:00')));
      expect(verdict(tester), ['마감', '오늘 17:00 마감']);
      expect(verdictColor(tester, '오늘 17:00 마감'), light.urgent);
      await pumpReport(tester, reportNotice(deadline: _day('2026-10-17')));
      expect(verdict(tester), ['마감', '오늘 마감']);
    });
  });

  testWidgets('서버는 확인 필요인데 충족 줄만 있으면(누구나 지원 가능 + 첨부 미확인) 원문 확인 안내', (tester) async {
    await pumpReport(
      tester,
      Notice(
        summary: reportNotice(deadline: _day('2026-10-30')).summary,
        description: null,
        applicationStart: null,
        activityPeriod: null,
        eligibility: const Eligibility(
          conditions: [],
          unresolvedEvidence: [],
          preferredEvidence: [],
          extractionComplete: false,
          explicitlyUnrestricted: true,
          unrestrictedEvidence: '참가대상: 누구나',
        ),
        lastVerifiedAt: null,
      ),
      recommendation: rec('needs_check'),
    );
    expect(verdict(tester).take(2), ['조건', '지원 조건 확인 필요']);
    expect(findText('조건 1개 충족. 원문에서 한 번 더 확인해 주세요.'), findsOneWidget);
    expect(findTextContaining('비교했습니다'), findsNothing);
  });

  testWidgets('큰 글자(1.3배)에서 결론 카드 아이콘·이름표가 값 첫 줄과 세로 가운데로 맞는다', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpReport(
      tester,
      reportNotice(deadline: _day('2026-10-30')),
      recommendation: rec('needs_check', results: const [_grade], reasons: const ['interest_match']),
    );
    final card = find.byKey(reportVerdictKey);
    for (final (icon, name, value) in [
      (Icons.checklist_rounded, '조건', '확인 필요 1개 · 학년'),
      (Icons.event_rounded, '마감', '10월 30일 마감 · D-13'),
      (Icons.star_outline_rounded, '추천', '관심 분야 관련'),
    ]) {
      final v = tester.getRect(find.descendant(of: card, matching: findText(value)));
      final i = tester.getRect(find.descendant(of: card, matching: find.byIcon(icon)));
      final n = tester.getRect(find.descendant(of: card, matching: find.text(name)));
      expect(i.center.dy, closeTo(v.center.dy, 1), reason: name); // 값이 한 줄이면 줄 가운데
      expect(n.center.dy, closeTo(v.center.dy, 1), reason: name);
      expect(i.height, closeTo(18 * 1.3, 0.5), reason: name); // 아이콘도 글자 배율을 따른다
    }
  });

  group('순서', () {
    testWidgets('제목·출처 → 결론 카드 → … → 체크리스트 → 일정 → 추천 이유', (tester) async {
      await pumpReport(
        tester,
        reportNotice(deadline: _day('2026-10-30')),
        recommendation: rec('met', results: const [_majorMet], reasons: const ['interest_match']),
      );
      double top(Finder f) => tester.getTopLeft(f).dy;
      final card = top(find.byKey(reportVerdictKey));
      expect(top(find.text('학교 공지')), lessThan(card));
      expect(card, lessThan(top(find.text('지원 전 체크리스트'))));
      expect(top(find.text('지원 전 체크리스트')), lessThan(top(find.text('일정'))));
      expect(top(find.text('일정')), lessThan(top(find.text('추천 이유'))));
      expect(findTextContaining('합격 가능성과는 관계없습니다.'), findsOneWidget);
    });
  });

  group('체크리스트: 확인할 것 먼저, 충족 접기', () {
    String? none(String _) => null;

    test('미충족 → 확인 필요 → 충족 → 안내, 같은 상태 안에서는 원래 순서', () {
      final rows = checklistRows(
        reportNotice(unresolved: ['자격증 소지자']),
        rec('not_met', results: const [_majorMet, _uniMet, _gradeNotMet, _grade]),
        none,
      );
      expect(rows.map((r) => (r.state, r.field)), [
        (CheckState.notMet, '학년'),
        (CheckState.check, '학년'),
        (CheckState.check, null),
        (CheckState.met, '학과'),
        (CheckState.met, '학교'),
      ]);
      final info = checklistRows(
        Notice(
          summary: reportNotice().summary,
          description: null,
          applicationStart: null,
          activityPeriod: null,
          eligibility: const Eligibility(
            conditions: [],
            unresolvedEvidence: ['운전면허 소지자', '야간 근무 가능자'],
            preferredEvidence: ['운전면허 소지자'],
            extractionComplete: true,
            explicitlyUnrestricted: false,
            unrestrictedEvidence: null,
          ),
          lastVerifiedAt: null,
        ),
        rec('needs_check', results: const [_majorMet]),
        none,
      );
      expect(info.map((r) => r.state), [CheckState.check, CheckState.met, CheckState.info]);
    });

    testWidgets('확인할 줄이 있고 충족이 2개 이상이면 충족 N개로 접고 눌러 펼친다', (tester) async {
      await pumpReport(
        tester,
        reportNotice(deadline: _day('2026-10-30')),
        recommendation: rec('needs_check', results: const [_majorMet, _uniMet, _grade]),
      );
      expect(findText('충족 2개'), findsOneWidget);
      expect(find.text('명지전문대'), findsNothing); // 충족 근거는 접혀 있다
      expect(findText('조건 2개 충족. 1개는 직접 확인해 주세요.'), findsOneWidget); // 안내 문장은 그대로
      // 확인 필요 줄이 접힌 충족 줄보다 위
      expect(tester.getTopLeft(find.text('프로필 미입력')).dy, lessThan(tester.getTopLeft(findText('충족 2개')).dy));
      await tester.tap(findText('충족 2개'));
      await tester.pumpAndSettle();
      expect(find.text('명지전문대'), findsOneWidget);
      expect(find.text('접기'), findsOneWidget);
      await tester.tap(find.text('접기'));
      await tester.pumpAndSettle();
      expect(find.text('명지전문대'), findsNothing);
    });

    testWidgets('충족 줄만 있으면 접지 않는다', (tester) async {
      await pumpReport(tester, reportNotice(), recommendation: rec('met', results: const [_majorMet, _uniMet]));
      expect(findTextContaining('충족 2개'), findsNothing);
      expect(find.text('명지전문대'), findsOneWidget);
      expect(find.text('컴퓨터공학과'), findsOneWidget);
    });

    testWidgets('충족이 1개면 접지 않는다', (tester) async {
      await pumpReport(tester, reportNotice(), recommendation: rec('needs_check', results: const [_majorMet, _grade]));
      expect(findTextContaining('충족 1개'), findsNothing);
      expect(find.text('컴퓨터공학과'), findsOneWidget);
    });
  });
}
