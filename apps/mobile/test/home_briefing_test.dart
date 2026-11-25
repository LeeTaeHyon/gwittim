import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/main.dart';
import 'package:gwittim/ui/briefing_data.dart';
import 'package:gwittim/ui/briefing_screen.dart';
import 'package:gwittim/ui/briefing_stats.dart';
import 'package:gwittim/ui/calendar_screen.dart';
import 'package:gwittim/ui/components.dart';
import 'package:gwittim/ui/home_screen.dart';
import 'package:gwittim/ui/home_sections.dart';
import 'package:gwittim/ui/icons.dart';
import 'package:gwittim/ui/notices_screen.dart';
import 'package:gwittim/ui/theme.dart';

import 'finders.dart';

final today = DateTime(2026, 10, 17);

DateInfo day(String date) => DateInfo(date: date, time: null, timezone: null, precision: 'date', evidence: date);

NoticeSummary summary(
  String id, {
  String? deadline,
  String category = 'contest',
  String? published,
  String? sourceUrl = 'https://example.invalid/x',
  String lifecycle = 'open',
}) => NoticeSummary(
  noticeId: id,
  noticeVersion: 1,
  title: id,
  category: category,
  sourceUrl: sourceUrl,
  published: published == null ? null : day(published),
  applicationDeadline: deadline == null ? null : day(deadline),
  deadlineNote: null,
  lifecycleStatus: lifecycle,
);

RecommendationEntry entry(
  String id, {
  String? deadline,
  List<String> reasons = const [],
  String status = 'needs_check',
  String category = 'contest',
  String? published,
  String? sourceUrl = 'https://example.invalid/x',
  String lifecycle = 'open',
}) => RecommendationEntry(
  recommendation: Recommendation(noticeId: id, score: null, eligibilityStatus: status, reasonCodes: reasons),
  notice: summary(
    id,
    deadline: deadline,
    category: category,
    published: published,
    sourceUrl: sourceUrl,
    lifecycle: lifecycle,
  ),
);

/// 저장한 공고. [was]를 주지 않으면 저장 뒤 마감이 바뀌지 않은 공고다.
SavedEntry savedOne(String id, {String? deadline, String? was}) => SavedEntry(
  saved: SavedNotice(
    noticeId: id,
    savedAt: today,
    savedNoticeVersion: 1,
    savedDeadlineSnapshot: (was ?? deadline) == null ? null : day(was ?? deadline!),
  ),
  notice: summary(id, deadline: deadline),
);

RecommendationList list(List<RecommendationEntry> items, {bool personalized = true}) =>
    RecommendationList(mode: personalized ? 'personalized' : 'latest', items: items, generatedAt: today);

const interest = ['interest_match'];

Future<SampleNoticeRepository> loaded(WidgetTester tester) async {
  final repo = SampleNoticeRepository();
  await tester.runAsync(repo.preload);
  return repo;
}

void reduceMotion(WidgetTester tester) {
  tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

void bigScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// 추천 목록·저장 목록만 바꿔 끼운 샘플 저장소. 프로필은 샘플 그대로(맞춤이면 컴퓨터공학과, 최신 모드면 없음).
class ListRepo extends SampleNoticeRepository {
  ListRepo(this.items, {this.saved = const [], super.personalized});

  final List<RecommendationEntry> items;
  final List<SavedEntry> saved;

  @override
  Future<RecommendationList> listRecommendations() async => list(items, personalized: personalized);

  @override
  Future<List<SavedEntry>> listSaved() async => saved;
}

/// 언제 '연 것'으로 기록했는지 남기는 저장소. 처음부터 오늘 연 것으로 답해 도착 장면이 뜨지 않는다.
class _RecordingStore extends MemoryBriefingStore {
  _RecordingStore() : super(alwaysShown: true);

  final marked = <DateTime>[];

  @override
  Future<void> markShown(DateTime day) {
    marked.add(day);
    return super.markShown(day);
  }
}

Future<void> pumpApp(WidgetTester tester, BriefingStore store) async {
  await tester.pumpWidget(
    GwittimApp(repository: await loaded(tester), openUrl: (_) async => true, today: today, briefingStore: store),
  );
}

Future<void> pumpHome(WidgetTester tester, ListRepo repo, {BriefingStore? store}) async {
  await tester.runAsync(repo.preload);
  await tester.pumpWidget(const SizedBox()); // 같은 테스트에서 다시 부르면 홈을 새로 만든다
  await tester.pumpWidget(
    GwittimApp(
      repository: repo,
      openUrl: (_) async => true,
      today: today,
      briefingStore: store ?? MemoryBriefingStore(alwaysShown: true),
    ),
  );
  await tester.pumpAndSettle();
}

/// 홈 줄에서 [title] 공고의 메타 줄(제목 바로 아래 글)
Finder metaOf(String title) => find.descendant(
  of: find.ancestor(of: findText(title), matching: find.byType(Column)).first,
  matching: find.byWidgetPredicate((w) => w is Text && w.textSpan != null && w.data == null),
);

String plain(WidgetTester tester, Finder f) =>
    tester.widget<Text>(f).textSpan!.toPlainText().replaceAll('⁠', '').replaceAll(' ', ' ');

/// 화면에 그려진 대로 줄마다 나눈 글(보이지 않는 문자는 빼고, 줄바꿈 없는 공백은 일반 공백으로).
List<String> visualLines(WidgetTester tester, Finder text) {
  final p = tester.renderObject<RenderParagraph>(find.descendant(of: text, matching: find.byType(RichText)));
  final s = p.text.toPlainText();
  final lines = <double, StringBuffer>{};
  double? top;
  for (var i = 0; i < s.length; i++) {
    final boxes = p.getBoxesForSelection(TextSelection(baseOffset: i, extentOffset: i + 1));
    if (boxes.isNotEmpty) top = boxes.first.top;
    if (top != null) lines.putIfAbsent(top, StringBuffer.new).write(s[i]);
  }
  return [for (final b in lines.values) b.toString().replaceAll('⁠', '').replaceAll(' ', ' ').trim()];
}

/// 360 폭 폰, 기기 글자 크기 [scale]배 (앱 안에서는 1.3배까지만 커진다)
void phone360(WidgetTester tester, double scale) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void main() {
  group('겹치지 않는 공고 수와 숫자 칸', () {
    test('같은 공고가 여러 소식에 있어도 한 건으로 센다', () {
      final b = buildBriefing(
        list([
          entry('겹침', deadline: '2026-10-18', reasons: interest, published: '2026-10-16'),
          entry('임박', deadline: '2026-10-21', reasons: interest),
          entry('직무', reasons: ['role_match']),
          entry('관련없음', deadline: '2026-10-19'), // 맞춤 추천이라 마감 임박 후보가 아니다
        ]),
        [savedOne('겹침', deadline: '2026-10-18'), savedOne('바뀜', deadline: '2026-10-25', was: '2026-10-22')],
        today,
        hasInterests: true,
      );
      expect(b.urgentIds, {'겹침', '임박'});
      expect(b.savedSoon.map((e) => e.notice.noticeId), ['겹침']);
      expect(b.fresh.map((e) => e.notice.noticeId), ['겹침']);
      expect(b.career.map((e) => e.notice.noticeId), ['직무']);
      expect(b.changed.map((e) => e.notice.noticeId), ['바뀜']);
      // 겹침, 임박, 직무, 바뀜 (소식별 합 6건이 아니라 4건)
      expect(distinctNoticeCount(b), 4);
    });

    test('졸업생 진로 추천은 수에는 넣고 숫자 칸에는 넣지 않는다', () {
      final e = entry('추천', deadline: '2026-10-20', reasons: ['major_prior_match']);
      final b = Briefing(majorPick: e);
      expect(distinctNoticeCount(b), 1);
      expect(briefingStats(b), isEmpty);
    });

    test('칸은 우선순위대로 0건을 빼고 최대 3칸', () {
      final one = entry('a', deadline: '2026-10-20', reasons: interest);
      final b = Briefing(
        urgentIds: {'a', 'b'},
        savedSoon: [savedOne('s', deadline: '2026-10-18')],
        fresh: [one],
        career: [one],
        changed: [savedOne('c', deadline: '2026-10-25', was: '2026-10-22')],
      );
      expect(
        [for (final s in briefingStats(b)) (s.kind, s.count)],
        [(BriefingStatKind.urgent, 2), (BriefingStatKind.savedSoon, 1), (BriefingStatKind.fresh, 1)],
      );
      // 마감 임박이 0건이면 뒤 칸이 앞으로
      final c = Briefing(fresh: [one], changed: b.changed);
      expect([for (final s in briefingStats(c)) s.kind], [BriefingStatKind.fresh, BriefingStatKind.changed]);
    });

    testWidgets('머리의 숫자 칸은 공유하는 위젯이라 0건 칸이 없고 이름과 개수가 읽힌다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: gwittimTheme(),
          home: BriefingScreen(
            briefing: Briefing(
              urgentIds: {'a', 'b'},
              fresh: [entry('n', reasons: interest)],
            ),
            today: today,
            onOpenNotice: (_, _) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder inRow(String text) => find.descendant(of: find.byType(BriefingStatRow), matching: find.text(text));
      expect(inRow('마감 임박'), findsOneWidget);
      expect(inRow('새 공고'), findsOneWidget);
      expect(inRow('저장 곧 마감'), findsNothing);
      expect(inRow('진로 관련'), findsNothing);
      expect(inRow('2'), findsOneWidget);
    });
  });

  group('홈 한 목록 계산 (D-050)', () {
    HomeSections build(
      List<RecommendationEntry> items, {
      List<SavedEntry> saved = const [],
      bool personalized = true,
      MajorPickState picks = const MajorPickState(),
    }) => buildHomeSections(
      list(items, personalized: personalized),
      saved,
      today,
      picks: picks,
      majorId: 'm',
    );

    List<String> ids(List<HomeRow> rows) => [for (final r in rows) r.id];

    test('저장·마감 후보·새 공고·추천 상위에 모두 걸린 공고도 홈 줄에는 한 번만', () {
      final h = build(
        [
          entry('겹침', deadline: '2026-10-19', reasons: interest, published: '2026-10-16'),
          entry('새것', deadline: '2026-11-20', reasons: interest, published: '2026-10-17'),
          entry('먼 것', deadline: '2026-11-30', reasons: ['role_match']),
        ],
        saved: [savedOne('겹침', deadline: '2026-10-19')],
      );
      expect(h.rowIds, ['겹침', '새것', '먼 것']);
      expect(h.rowIds.toSet(), hasLength(h.rowIds.length));
      final row = h.deadlines.single;
      expect(row.saved, isNotNull); // 저장 정보와 추천 정보를 함께 담는다
      expect(row.recommendation, isNotNull);
      expect(row.fresh, isTrue);
    });

    test('이번 주 마감: 7일 안만, 마감순, 같은 날이면 저장한 공고 → 추천 순서, 5건까지와 전체 수', () {
      final h = build(
        [
          entry('8일', deadline: '2026-10-25', reasons: interest),
          entry('같은 날 앞', deadline: '2026-10-20', reasons: interest),
          entry('같은 날 뒤', deadline: '2026-10-20', reasons: interest),
          entry('오늘', deadline: '2026-10-17', reasons: interest),
          entry('7일', deadline: '2026-10-24', reasons: interest),
          entry('6일', deadline: '2026-10-23', reasons: interest),
          entry('관련 없음', deadline: '2026-10-18'), // 맞춤 추천이면 관련 공고만 후보
        ],
        saved: [
          savedOne('저장만', deadline: '2026-10-20'), // 추천 목록에 없는 저장 공고
          savedOne('같은 날 뒤', deadline: '2026-10-20'),
        ],
      );
      expect(ids(h.deadlines), ['오늘', '같은 날 뒤', '저장만', '같은 날 앞', '6일']);
      expect(h.weekTotal, 6); // 오늘·같은 날 셋·6일·7일
      expect(h.isNext, isFalse);
      expect(h.deadlines.firstWhere((r) => r.id == '저장만').recommendation, isNull);
    });

    test('졸업생 진로 추천도 7일 안이면 마감 줄에, 관심 없다고 한 공고는 빼고 (D-021)', () {
      final items = [
        entry('통계', deadline: '2026-10-19', reasons: ['major_prior_match']),
        entry('통계 싫음', deadline: '2026-10-18', reasons: ['major_prior_match']),
      ];
      final declined = const MajorPickState().answer('통계 싫음', false, 'm', today);
      final h = build(items, picks: declined);
      expect(ids(h.deadlines), ['통계']);
      expect(h.deadlines.single.majorPick, isTrue);
    });

    test('7일 안이 없으면 8~14일 안 가장 가까운 1건이 다음 마감, 그것도 없으면 빈 목록', () {
      final next = build([
        entry('15일', deadline: '2026-11-01', reasons: interest),
        entry('13일', deadline: '2026-10-30', reasons: interest),
        entry('9일', deadline: '2026-10-26', reasons: interest),
      ]);
      expect(ids(next.deadlines), ['9일']);
      expect(next.isNext, isTrue);
      expect(next.weekTotal, 0);

      final none = build([entry('15일', deadline: '2026-11-01', reasons: interest)]);
      expect(none.deadlines, isEmpty);
      expect(none.isNext, isFalse);
    });

    test('새 공고가 이번 주 마감 줄에 있으면 새 공고 구역에는 없고 줄에 표시만', () {
      final h = build([
        entry('새 임박', deadline: '2026-10-18', reasons: interest, published: '2026-10-17'),
        entry('새 먼 것', deadline: '2026-11-20', reasons: interest, published: '2026-10-15'),
        entry('오래된 것', deadline: '2026-11-20', reasons: interest, published: '2026-10-14'),
        entry('관련 없는 새것', published: '2026-10-17'),
      ]);
      expect(ids(h.deadlines), ['새 임박']);
      expect(h.deadlines.single.fresh, isTrue);
      expect(ids(h.fresh), ['새 먼 것']);
    });

    test('새 공고는 3건까지, 추천 순서대로', () {
      final h = build([for (var i = 1; i <= 5; i++) entry('새$i', reasons: interest, published: '2026-10-16')]);
      expect(ids(h.fresh), ['새1', '새2', '새3']);
      expect(h.nudge?.fresh, 5); // 말풍선은 전체 수
    });

    test('마감이 먼 맞춤 공고에는 7일 안 후보(화면 밖 포함)와 관련 이유 없는 공고가 없다', () {
      final h = build([
        for (var i = 1; i <= 6; i++) entry('임박$i', deadline: '2026-10-${17 + i}', reasons: interest),
        entry('관련 없음', deadline: '2026-12-01'),
        entry('통계', deadline: '2026-12-01', reasons: ['major_prior_match']),
        entry('먼 것', deadline: '2026-12-01', reasons: ['major_match']),
        entry('마감일 없음', reasons: ['role_match']),
      ]);
      expect(h.deadlines, hasLength(5));
      expect(h.weekTotal, 6);
      expect(ids(h.later), ['먼 것', '마감일 없음']); // 화면 밖 '임박6'은 넣지 않는다
    });

    test('관련 공고가 없으면 마감이 먼 맞춤 공고를 채우지 않는다', () {
      final h = build([entry('관련 없음', deadline: '2026-12-01'), entry('또', deadline: '2026-12-02')]);
      expect(h.later, isEmpty);
      expect(h.fresh, isEmpty);
    });

    test('마감일이 없거나 모집 중이 아닌 공고는 마감 줄에 없다', () {
      final h = build([
        entry('선착순', reasons: interest),
        entry('마감됨', deadline: '2026-10-18', reasons: interest, lifecycle: 'closed'),
        entry('미상', deadline: '2026-10-18', reasons: interest, lifecycle: 'unknown'),
        entry('지난 마감', deadline: '2026-10-16', reasons: interest),
      ]);
      expect(h.deadlines, isEmpty);
    });

    test('말풍선: 오늘 마감(저장·관련 후보만), 마감 변경, 새 공고. 셋 다 0이면 없다', () {
      final items = [
        entry('오늘 관련', deadline: '2026-10-17', reasons: interest),
        entry('오늘 통계', deadline: '2026-10-17', reasons: ['major_prior_match']), // C는 세지 않는다
        entry('오늘 무관', deadline: '2026-10-17'),
        entry('새것', reasons: ['role_match'], published: '2026-10-16'),
      ];
      final saved = [
        savedOne('오늘 관련', deadline: '2026-10-17'),
        savedOne('저장 오늘', deadline: '2026-10-17'),
        savedOne('바뀜', deadline: '2026-10-30', was: '2026-10-28'),
      ];
      final h = build(items, saved: saved);
      expect(h.nudge?.dueToday, 2);
      expect(h.nudge?.changed, 1);
      expect(h.nudge?.fresh, 1);
      // 말풍선이 있으면 브리핑도 비어 있지 않다
      expect(buildBriefing(list(items), saved, today, majorId: 'm').isEmpty, isFalse);

      expect(build([entry('먼 것', deadline: '2026-10-22', reasons: interest)]).nudge, isNull);
    });

    test('말풍선이 생기는 경우마다 브리핑이 비어 있지 않다', () {
      final cases = <(List<RecommendationEntry>, List<SavedEntry>)>[
        ([entry('오늘', deadline: '2026-10-17', reasons: interest)], const []),
        (const [], [savedOne('저장 오늘', deadline: '2026-10-17')]),
        (const [], [savedOne('바뀜', deadline: '2026-11-30', was: '2026-11-20')]),
        ([entry('새것', reasons: interest, published: '2026-10-17')], const []),
      ];
      for (final (items, saved) in cases) {
        final h = buildHomeSections(list(items), saved, today);
        expect(h.nudge, isNotNull);
        expect(buildBriefing(list(items), saved, today).isEmpty, isFalse);
      }
    });

    test('최신 모드: 새 공고·마감이 먼 구역 없이 마감 줄 3건, 오늘 마감은 저장한 공고만 센다', () {
      final h = build(
        [
          for (var i = 0; i < 5; i++) entry('최신$i', deadline: '2026-10-${17 + i}', published: '2026-10-17'),
          entry('먼 것', deadline: '2026-12-01'),
        ],
        saved: [savedOne('저장 오늘', deadline: '2026-10-17')],
        personalized: false,
      );
      expect(h.personalized, isFalse);
      expect(h.deadlines, hasLength(3));
      expect(h.weekTotal, 6);
      expect(h.fresh, isEmpty);
      expect(h.later, isEmpty);
      expect(h.nudge?.dueToday, 1); // '최신0'은 오늘 마감이지만 저장하지 않아 세지 않는다
      expect(h.nudge?.fresh, 0);
    });

    test('마감 변경 카드: 마감 줄에 나온 공고는 빼고 남은 것만', () {
      final h = build(
        const [],
        saved: [
          savedOne('줄에 나옴', deadline: '2026-10-19', was: '2026-10-16'),
          savedOne('먼 변경', deadline: '2026-11-30', was: '2026-11-20'),
        ],
      );
      expect(ids(h.deadlines), ['줄에 나옴']);
      expect(h.deadlines.single.deadlineChanged, isTrue);
      expect(h.changed.map((s) => s.notice.noticeId), ['먼 변경']);
      expect(h.nudge?.changed, 2);
    });

    test('마감 변경 카드: 새 공고·마감이 먼 맞춤 공고 줄에 나온 공고도 카드가 없다', () {
      final h = build(
        [
          entry('새 변경', deadline: '2026-12-10', reasons: interest, published: '2026-10-16'),
          entry('먼 변경', deadline: '2026-11-30', reasons: interest),
        ],
        saved: [
          savedOne('새 변경', deadline: '2026-12-10', was: '2026-12-01'),
          savedOne('먼 변경', deadline: '2026-11-30', was: '2026-11-20'),
          savedOne('줄 없음', deadline: '2026-11-28', was: '2026-11-21'),
        ],
      );
      expect(ids(h.fresh), ['새 변경']);
      expect(ids(h.later), ['먼 변경']);
      expect(h.later.single.deadlineChanged, isTrue);
      expect(h.changed.map((s) => s.notice.noticeId), ['줄 없음']);
      expect(h.rowIds.where((id) => id == '먼 변경'), hasLength(1));
      expect(h.nudge?.changed, 3); // 말풍선은 줄에 나왔든 아니든 모두 센다
    });

    test('추천 이유 표기: 하나면 낱말 그대로, 둘 이상이면 줄여 잇는다', () {
      Recommendation rec(List<String> codes) =>
          Recommendation(noticeId: 'x', score: null, eligibilityStatus: 'met', reasonCodes: codes);
      expect(homeReason(rec(['interest_match']), personalized: true), '관심 분야');
      expect(homeReason(rec(['role_match', 'deadline_timing']), personalized: true), '희망 직무');
      expect(homeReason(rec(['major_match']), personalized: true), '전공');
      expect(homeReason(rec(['major_match', 'interest_match']), personalized: true), '관심·전공');
      expect(homeReason(rec(['role_match', 'major_match']), personalized: true), '직무·전공');
      expect(homeReason(rec(['interest_match', 'role_match']), personalized: true), '관심·직무');
      expect(
        homeReason(rec(['interest_match', 'role_match', 'major_match', 'major_prior_match']), personalized: true),
        '관심·직무·전공',
      );
      expect(homeReason(rec(['major_prior_match']), personalized: true), '');
      expect(homeReason(rec(['interest_match']), personalized: false), '');
      expect(homeReason(null, personalized: true), '');
    });
  });

  group('홈 귀띔 말풍선과 도착 장면', () {
    testWidgets('도착 장면 뒤 브리핑을 닫으면 홈에 말풍선, 오늘 연 것으로 기록', (tester) async {
      final store = MemoryBriefingStore();
      await pumpApp(tester, store);
      await tester.pumpAndSettle();
      await tester.tap(find.text('확인'));
      await tester.pumpAndSettle();
      expect(findText('새 공고 1건'), findsOneWidget); // 샘플: 관련 새 공고 1건, 7일 안 마감 없음
      expect(find.text('브리핑 다시 보기'), findsNothing);
      expect(find.text('새 소식'), findsNothing);
      expect(await store.shownOn(today), isTrue);
    });

    testWidgets('도착 장면: 말풍선 → 날짜 → 확인할 공고 N건 → 사라진 뒤 브리핑, 화면 읽기 이름', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpApp(tester, MemoryBriefingStore());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final scene = find.byWidgetPredicate(
        (w) => w is Semantics && (w.properties.label ?? '').startsWith('오늘의 귀띔 도착, 확인할 공고 '),
      );
      expect(scene, findsOneWidget);
      expect(findTextContaining('· 오늘의 귀띔'), findsOneWidget);
      expect(find.text('10월 17일 토요일 · 오늘의 귀띔'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 2600)); // 장면이 거의 끝남
      await tester.pump(const Duration(milliseconds: 300));
      expect(scene, findsNothing);
      expect(find.byType(BriefingScreen), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('주요 소식'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('장면 아무 곳이나 누르면 바로 브리핑', (tester) async {
      await pumpApp(tester, MemoryBriefingStore());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(findTextContaining('· 오늘의 귀띔'), findsOneWidget);
      await tester.tapAt(const Offset(40, 300));
      await tester.pump();
      expect(findTextContaining('· 오늘의 귀띔'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('주요 소식'), findsOneWidget);
    });

    testWidgets('애니메이션 줄이기면 장면 없이 바로 브리핑', (tester) async {
      reduceMotion(tester);
      await pumpApp(tester, MemoryBriefingStore());
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(findTextContaining('· 오늘의 귀띔'), findsNothing);
      expect(find.byType(BriefingScreen), findsOneWidget);
      expect(find.text('주요 소식'), findsOneWidget);
    });

    testWidgets('말풍선: 오늘 마감 → 마감 변경 → 새 공고 순서, 오늘 마감 건수만 heroUrgent, 화면 읽기 이름', (tester) async {
      bigScreen(tester);
      final semantics = tester.ensureSemantics();
      await pumpHome(
        tester,
        ListRepo(
          [
            entry('오늘 하나', deadline: '2026-10-17', reasons: interest),
            entry('오늘 둘', deadline: '2026-10-17', reasons: ['role_match'], published: '2026-10-16'),
            entry('새것', deadline: '2026-11-20', reasons: interest, published: '2026-10-15'),
          ],
          saved: [savedOne('바뀜', deadline: '2026-11-30', was: '2026-11-25')],
        ),
      );
      final bubble = findText('오늘 마감 2건 · 마감 변경 1건 · 새 공고 2건');
      expect(bubble, findsOneWidget);
      expect(find.bySemanticsLabel('오늘의 귀띔, 오늘 마감 2건, 마감 변경 1건, 새 공고 2건, 브리핑 열기'), findsOneWidget);
      final spans = <TextSpan>[];
      tester.widget<Text>(bubble).textSpan!.visitChildren((s) {
        if (s is TextSpan && (s.text ?? '').contains('건')) spans.add(s);
        return true;
      });
      expect(
        [for (final s in spans) s.style?.color],
        [GwColors.light.heroUrgent, GwColors.light.loginInk, GwColors.light.loginInk],
      );
      expect([for (final s in spans) s.style?.fontWeight], everyElement(FontWeight.w700));
      // 말풍선 면은 hero, 꼬리는 왼쪽 아래
      final face = tester.widget<Material>(find.ancestor(of: bubble, matching: find.byType(Material)).first);
      expect(face.color, GwColors.light.hero);
      expect((face.borderRadius! as BorderRadius).bottomLeft, const Radius.circular(6));
      expect(
        tester.getSize(find.ancestor(of: bubble, matching: find.byType(InkWell)).first).height,
        greaterThanOrEqualTo(48),
      );
      semantics.dispose();
    });

    for (final scale in [1.3, 2.0]) {
      testWidgets('말풍선: 폭 360·기기 글자 $scale배에서 줄마다 이름과 건수가 통째로, 가운뎃점은 줄 앞에 오지 않는다', (tester) async {
        phone360(tester, scale);
        await pumpHome(
          tester,
          ListRepo(
            [
              entry('오늘 하나', deadline: '2026-10-17', reasons: interest),
              entry('오늘 둘', deadline: '2026-10-17', reasons: ['role_match'], published: '2026-10-16'),
            ],
            saved: [savedOne('바뀜', deadline: '2026-11-30', was: '2026-11-25')],
          ),
        );
        expect(tester.takeException(), isNull);
        final bubble = findText('오늘 마감 2건 · 마감 변경 1건 · 새 공고 1건');
        expect(bubble, findsOneWidget);
        final lines = visualLines(tester, bubble);
        expect(lines.length, greaterThan(1)); // 이 폭에서는 줄이 바뀐다
        for (final part in ['오늘 마감 2건', '마감 변경 1건', '새 공고 1건']) {
          expect(lines.where((l) => l.contains(part)), hasLength(1), reason: '$part / $lines');
        }
        for (final l in lines) {
          expect(l.startsWith('·'), isFalse, reason: '$lines');
        }
      });
    }

    testWidgets('건수가 모두 0이면 말풍선이 없다', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpHome(tester, ListRepo([entry('먼 것', deadline: '2026-10-22', reasons: interest)]));
      expect(find.bySemanticsLabel(RegExp('^오늘의 귀띔')), findsNothing);
      expect(findTextContaining('건 · '), findsNothing);
      semantics.dispose();
    });

    testWidgets('말풍선을 누르면 도착 장면 없이 브리핑이 열리고, 연 것으로 기록', (tester) async {
      final store = _RecordingStore();
      await pumpHome(
        tester,
        ListRepo([entry('새것', reasons: interest, published: '2026-10-17')]),
        store: store,
      );
      expect(store.marked, isEmpty);
      await tester.tap(findText('새 공고 1건'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(BriefingScreen), findsOneWidget);
      expect(findTextContaining('· 오늘의 귀띔'), findsNothing);
      expect(store.marked, [today]);
      await tester.pumpAndSettle();
      await tester.tap(find.text('확인'));
      await tester.pumpAndSettle();
      expect(findText('새 공고 1건'), findsOneWidget); // 닫아도 말풍선은 그대로
    });
  });

  group('홈 구역과 줄 (D-050)', () {
    testWidgets('이번 주 마감 5줄, 넘치면 카드 안 N건 더 보기(달력으로 가지 않음), 마감이 먼 맞춤 공고 전체 보기는 공고 탭', (tester) async {
      bigScreen(tester);
      await pumpHome(
        tester,
        ListRepo([
          for (var i = 1; i <= 6; i++) entry('임박 $i', deadline: '2026-10-${17 + i}', reasons: interest),
          entry('먼 공고', deadline: '2026-12-01', reasons: interest),
        ]),
      );
      expect(find.text('이번 주 마감'), findsOneWidget);
      expect(findText('임박 5'), findsOneWidget);
      expect(findText('임박 6'), findsNothing);
      expect(find.text('마감이 먼 맞춤 공고'), findsOneWidget);
      expect(findText('먼 공고'), findsOneWidget);
      expect(find.text('새 공고'), findsNothing); // 새 공고가 없으면 구역을 숨긴다

      // 구역 제목 오른쪽은 늘 '앞으로 7일'. 넘치는 후보는 카드 맨 아래 펼침 줄로 그 자리에서 본다 (home-report-clarity-spec A2)
      expect(find.text('앞으로 7일'), findsOneWidget);
      expect(find.textContaining(RegExp(r'전체 \d+건')), findsNothing);
      await tester.tap(find.text('1건 더 보기'));
      await tester.pumpAndSettle();
      expect(find.byType(CalendarScreen), findsNothing);
      expect(findText('임박 6'), findsOneWidget);
      expect(find.text('접기'), findsOneWidget);
      expect(find.byType(NoticesScreen), findsNothing);
      await tester.tap(find.text('전체 보기'));
      await tester.pumpAndSettle();
      expect(find.byType(NoticesScreen), findsOneWidget);
    });

    testWidgets('5건 이하면 오른쪽은 앞으로 7일, 7일 안이 없으면 다음 마감·앞으로 2주', (tester) async {
      await pumpHome(tester, ListRepo([entry('임박', deadline: '2026-10-20', reasons: interest)]));
      expect(find.text('이번 주 마감'), findsOneWidget);
      expect(find.text('앞으로 7일'), findsOneWidget);

      await pumpHome(tester, ListRepo([entry('열흘', deadline: '2026-10-27', reasons: interest)]));
      expect(find.text('다음 마감'), findsOneWidget);
      expect(find.text('앞으로 2주'), findsOneWidget);
      expect(find.text('이번 주 마감'), findsNothing);

      await pumpHome(tester, ListRepo([entry('보름', deadline: '2026-11-01', reasons: interest)]));
      expect(find.text('이번 주 마감'), findsOneWidget);
      expect(findText('맞춤 공고 중 앞으로 2주 안에 마감되는 공고가 없습니다.'), findsOneWidget);
    });

    testWidgets('최신 모드: 곧 마감되는 공고 3줄, 넘치면 N건 더 보기로 펼침, 새 공고·마감이 먼 구역 없음', (tester) async {
      bigScreen(tester);
      await pumpHome(
        tester,
        ListRepo([
          for (var i = 0; i < 4; i++) entry('최신 $i', deadline: '2026-10-${18 + i}', published: '2026-10-17'),
        ], personalized: false),
      );
      expect(find.text('곧 마감되는 공고'), findsOneWidget);
      expect(find.text('앞으로 7일'), findsOneWidget);
      expect(find.textContaining(RegExp(r'전체 \d+건')), findsNothing);
      expect(findText('최신 2'), findsOneWidget);
      expect(findText('최신 3'), findsNothing);
      expect(find.text('1건 더 보기'), findsOneWidget);
      expect(find.text('새 공고'), findsNothing);
      expect(find.text('마감이 먼 맞춤 공고'), findsNothing);
      expect(findText('현재 마감이 가까운 순으로 표시합니다'), findsOneWidget);
      // 비교할 프로필이 없어 줄에 조건 상태 원을 두지 않는다
      expect(find.descendant(of: find.byType(HomeScreen), matching: find.byType(EligibilityDot)), findsNothing);

      await tester.tap(find.text('1건 더 보기'));
      await tester.pumpAndSettle();
      expect(findText('최신 3'), findsOneWidget);
      expect(find.text('접기'), findsOneWidget);

      // 후보가 줄 수(3) 이하면 펼침 줄이 없다
      await pumpHome(
        tester,
        ListRepo([
          for (var i = 0; i < 3; i++) entry('최신 $i', deadline: '2026-10-${18 + i}', published: '2026-10-17'),
        ], personalized: false),
      );
      expect(findText('최신 2'), findsOneWidget);
      expect(find.textContaining('더 보기'), findsNothing);
      expect(find.textContaining(RegExp(r'전체 \d+건')), findsNothing);
    });

    testWidgets('맞춤 홈 줄: 상태 원은 오른쪽 화살표 옆에 줄 세로 가운데, 이유 칩은 제목 위', (tester) async {
      bigScreen(tester);
      await pumpHome(
        tester,
        ListRepo([
          entry('새 임박', deadline: '2026-10-19', reasons: interest, published: '2026-10-17'),
          entry('먼 공고', deadline: '2026-12-01', reasons: interest),
        ]),
      );
      final dots = find.descendant(of: find.byType(HomeScreen), matching: find.byType(EligibilityDot));
      expect(dots, findsNWidgets(2));
      for (final (i, title) in ['새 임박', '먼 공고'].indexed) {
        final line = tester.getRect(find.ancestor(of: findText(title), matching: find.byType(InkWell)).first);
        final t = tester.getRect(findText(title));
        final d = tester.getRect(dots.at(i));
        // 줄 세로 가운데, 제목·메타보다 오른쪽, 화살표 바로 왼쪽
        expect(d.center.dy, closeTo(line.center.dy, 0.5), reason: title);
        expect(d.left, greaterThanOrEqualTo(t.right - 0.5), reason: title);
        expect(d.left, greaterThanOrEqualTo(tester.getRect(metaOf(title)).right - 0.5), reason: title);
        final arrow = tester.getRect(find.descendant(of: find.ancestor(of: findText(title), matching: find.byType(InkWell)).first, matching: find.byIcon(Icons.chevron_right_rounded)));
        expect(arrow.left, greaterThan(d.right), reason: title);
        expect(arrow.center.dy, closeTo(d.center.dy, 0.5), reason: title);
        // 이유 칩은 제목 위
        final chip = tester.getRect(find.descendant(of: find.ancestor(of: findText(title), matching: find.byType(InkWell)).first, matching: find.text('관심 분야')));
        expect(chip.bottom, lessThanOrEqualTo(t.top), reason: title);
      }
    });

    testWidgets('글자 1.3배에서 메타가 넘쳐도 가운뎃점이 줄 끝에 남지 않는다', (tester) async {
      phone360(tester, 1.3);
      await pumpHome(
        tester,
        ListRepo([
          entry(
            '긴 메타',
            deadline: '2026-10-23',
            reasons: ['interest_match', 'role_match', 'major_match'],
          ),
        ]),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('관심·직무·전공'), findsOneWidget); // 이유는 제목 위 칩
      final lines = visualLines(tester, metaOf('긴 메타'));
      expect(lines.join(' '), 'D-6 · 공모전·경진대회');
      for (final l in lines) {
        expect(l.endsWith('·') || l.endsWith('· '), isFalse, reason: '$lines');
      }
    });

    testWidgets('저장한 공고 줄: 표시, 마감 변경 문구, 아래 변경 카드는 줄에 없는 공고만', (tester) async {
      bigScreen(tester);
      await pumpHome(
        tester,
        ListRepo(
          [entry('관련', deadline: '2026-10-20', reasons: interest)],
          saved: [
            savedOne('저장 바뀜', deadline: '2026-10-19', was: '2026-10-16'),
            savedOne('먼 변경', deadline: '2026-11-30', was: '2026-11-20'),
          ],
        ),
      );
      // 저장한 공고는 지원 건(D-052): '저장한 공고' 표시 대신 상태 칩, 남은 날은 모든 화면과 같은 문구
      expect(find.widgetWithText(Pill, '저장'), findsOneWidget);
      expect(plain(tester, metaOf('저장 바뀜')), 'D-2 · 10월 19일 마감 · 공모전·경진대회 · 마감 3일 연장');
      expect(plain(tester, metaOf('관련')), 'D-3 · 공모전·경진대회');
      expect(find.text('관심 분야'), findsOneWidget); // 이유 칩
      // 추천 정보가 없는 저장 공고에는 상태 원이 없다(관련 공고 줄에만 하나)
      expect(find.descendant(of: find.byType(HomeScreen), matching: find.byType(EligibilityDot)), findsOneWidget);
      expect(findTextContaining('저장한 공고의 마감 3일 연장'), findsNothing);
      expect(findTextContaining('저장한 공고의 마감 10일 연장'), findsOneWidget);
    });

    testWidgets('마감이 바뀐 저장 공고가 마감이 먼 맞춤 공고 줄에 나오면 한 번만, 메타에 변경 문구, 카드 없음', (tester) async {
      bigScreen(tester);
      await pumpHome(
        tester,
        ListRepo(
          [entry('먼 변경', deadline: '2026-11-30', reasons: interest)],
          saved: [savedOne('먼 변경', deadline: '2026-11-30', was: '2026-11-20')],
        ),
      );
      expect(find.text('마감이 먼 맞춤 공고'), findsOneWidget);
      expect(findText('먼 변경'), findsOneWidget);
      expect(plain(tester, metaOf('먼 변경')), 'D-44 · 11월 30일 마감 · 마감 10일 연장'); // 지원 건 남은 날 문구(D-052)
      final change = <TextSpan>[];
      tester.widget<Text>(metaOf('먼 변경')).textSpan!.visitChildren((s) {
        if (s is TextSpan && (s.text ?? '').replaceAll('⁠', '').contains('연장')) change.add(s);
        return true;
      });
      expect(change.single.style?.color, GwColors.light.sub);
      expect(change.single.style?.fontWeight, FontWeight.w600);
      expect(findTextContaining('저장한 공고의 마감'), findsNothing);
    });

    testWidgets('마감 줄: 표시와 메타(오늘 마감·시각·분류·이유), 졸업생 진로 추천은 이유 글자 없이', (tester) async {
      bigScreen(tester);
      final timed = RecommendationEntry(
        recommendation: const Recommendation(
          noticeId: '시각',
          score: null,
          eligibilityStatus: 'met',
          reasonCodes: ['interest_match', 'role_match', 'major_match'],
        ),
        notice: NoticeSummary(
          noticeId: '시각',
          noticeVersion: 1,
          title: '시각',
          category: 'event',
          sourceUrl: 'https://example.invalid/x',
          published: day('2026-10-17'),
          applicationDeadline: const DateInfo(
            date: '2026-10-17',
            time: '17:00',
            timezone: 'Asia/Seoul',
            precision: 'minute',
            evidence: '17:00',
          ),
          deadlineNote: null,
          lifecycleStatus: 'open',
        ),
      );
      await pumpHome(
        tester,
        ListRepo([
          timed,
          entry('통계', deadline: '2026-10-19', reasons: ['major_prior_match']),
        ]),
      );
      expect(plain(tester, metaOf('시각')), '오늘 마감 · 17:00 마감 · 행사');
      // 이유 칩: 별 아이콘 + accent 글자, 표시('새 공고')와 같은 줄
      final reason = tester.widget<Text>(find.text('관심·직무·전공'));
      expect(reason.style?.color, GwColors.light.accent);
      expect(reason.style?.fontSize, 13);
      expect(tester.getRect(find.text('관심·직무·전공')).top, closeTo(tester.getRect(find.descendant(of: find.byType(Pill), matching: find.text('새 공고'))).top, 0.5));
      expect(find.text('새 공고'), findsOneWidget); // 줄 위 표시. 같은 공고라 새 공고 구역은 없다
      expect(plain(tester, metaOf('통계')), 'D-2 · 공모전·경진대회');
      expect(find.byType(MajorPickLabel), findsOneWidget);
      expect(findTextContaining('조건 확인 필요'), findsNothing); // 상태 원이 대신한다
    });

    testWidgets('아이콘 줄: 분류 아이콘(분류 이름·분류색)과 상태 원, 메타는 마감 표기와 이유', (tester) async {
      bigScreen(tester);
      final semantics = tester.ensureSemantics();
      await pumpHome(
        tester,
        ListRepo([
          entry('새 공모전', deadline: '2026-12-20', reasons: interest, published: '2026-10-16', status: 'met'),
          entry('먼 장학', deadline: '2026-11-30', reasons: ['role_match', 'major_match'], category: 'scholarship'),
          entry('먼 알림톡', reasons: interest, sourceUrl: null),
          entry('먼 미충족', deadline: '2026-11-29', reasons: interest, category: 'mystery', status: 'not_met'),
        ]),
      );
      expect(find.text('새 공고'), findsOneWidget); // 구역 제목
      expect(find.text('최근 3일'), findsOneWidget);
      expect(plain(tester, metaOf('새 공모전')), '12월 20일 마감 · D-64');
      expect(plain(tester, metaOf('먼 장학')), '11월 30일 마감 · D-44');
      expect(plain(tester, metaOf('먼 알림톡')), '마감일 없음');
      expect(find.text('관심 분야'), findsNWidgets(3)); // 이유는 제목 위 칩
      expect(find.text('직무·전공'), findsOneWidget);

      final contest = tester.widget<Icon>(find.byIcon(Icons.emoji_events_rounded));
      expect(contest.size, 26);
      expect(contest.color, GwColors.light.category('contest'));
      expect(contest.semanticLabel, '공모전·경진대회');
      expect(tester.widget<Icon>(find.byIcon(Icons.savings_rounded)).color, GwColors.light.category('scholarship'));
      expect(tester.widget<Icon>(find.byIcon(Icons.more_horiz_rounded)).color, GwColors.light.category('other'));
      expect(
        find.descendant(of: find.byType(HomeScreen), matching: find.byType(GwIcon)),
        findsNWidgets(2),
      ); // 내 정보 + 알림톡
      for (final (status, icon) in [
        ('met', Icons.check_rounded),
        ('needs_check', Icons.question_mark_rounded),
        ('not_met', Icons.close_rounded),
      ]) {
        final dot = find.byWidgetPredicate((w) => w is EligibilityDot && w.status == status).first;
        expect(find.descendant(of: dot, matching: find.byIcon(icon)), findsOneWidget);
        expect(tester.getSize(dot), const Size(26, 26));
      }
      expect(find.bySemanticsLabel(RegExp('조건 충족')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('조건 미충족')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('공고 탭 카드는 분류 아이콘·상태 원 없이 글자 칩 그대로', (tester) async {
      bigScreen(tester);
      await pumpApp(tester, MemoryBriefingStore(alwaysShown: true));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(HomeScreen), matching: find.byType(NoticeCard)), findsNothing);
      await tester.tap(find.text('공고'));
      await tester.pumpAndSettle();
      final tabCards = find.descendant(of: find.byType(NoticesScreen), matching: find.byType(NoticeCard));
      expect(tabCards, findsWidgets);
      expect(find.descendant(of: tabCards, matching: find.byType(EligibilityDot)), findsNothing);
      expect(find.descendant(of: tabCards, matching: find.byIcon(Icons.emoji_events_rounded)), findsNothing);
      expect(find.descendant(of: tabCards, matching: find.byType(Pill)), findsWidgets);
    });

    testWidgets('360 폭·글자 1.3배: 상태 칩·새 공고 표시·이유 칩이 한 줄에 모자라면 칩 단위로 아랫줄, 넘치지 않음', (tester) async {
      phone360(tester, 1.3);
      await pumpHome(
        tester,
        ListRepo(
          [
            entry(
              '저장 새 공고',
              deadline: '2026-10-20',
              reasons: ['interest_match', 'role_match', 'major_match'],
              published: '2026-10-16',
            ),
          ],
          saved: [savedOne('저장 새 공고', deadline: '2026-10-20')],
        ),
      );
      expect(tester.takeException(), isNull);
      final state = tester.getRect(find.widgetWithText(Pill, '저장'));
      final fresh = tester.getRect(find.descendant(of: find.byType(Pill), matching: find.text('새 공고')));
      final reason = tester.getRect(find.text('관심·직무·전공'));
      final title = tester.getRect(findText('저장 새 공고'));
      expect(fresh.left, greaterThan(state.right)); // 표시 순서: 상태 → 새 공고 → 이유
      expect(reason.top, greaterThanOrEqualTo(fresh.top - 0.5));
      expect(reason.bottom, lessThanOrEqualTo(title.top)); // 칩은 모두 제목 위
      // 칩이 글 묶음 폭을 넘지 않는다(상태 원 왼쪽까지)
      final dot = tester.getRect(find.descendant(of: find.byType(HomeScreen), matching: find.byType(EligibilityDot)));
      expect(reason.right, lessThanOrEqualTo(dot.left));
      // 별 아이콘도 글자 배율을 따른다
      expect(tester.getSize(find.byIcon(Icons.star_rounded)).height, closeTo(14 * 1.3, 0.5));
    });

    testWidgets('마감 줄 날짜 블록: 큰 날짜와 요일(월 없음), 화면 읽기에서는 뺀다', (tester) async {
      bigScreen(tester);
      await pumpApp(tester, MemoryBriefingStore(alwaysShown: true));
      await tester.pumpAndSettle();
      expect(find.text('10월'), findsNothing);
      final dayNumber = find.descendant(of: find.byType(ExcludeSemantics), matching: find.text('30')); // 10월 30일(금)
      expect(dayNumber, findsWidgets);
      expect(find.descendant(of: find.byType(ExcludeSemantics), matching: find.text('금')), findsWidgets);
      expect(tester.getSize(find.ancestor(of: dayNumber.first, matching: find.byType(Container)).first).width, 44);
    });
  });

  group('이번 주 마감 카드 펼치기 (home-report-clarity-spec A)', () {
    /// 7일 안 후보 8건. 마감순 6~8번째는 최근 3일 안 게시라 접힌 홈에서는 아래 '새 공고' 구역에 나온다.
    List<RecommendationEntry> eight() => [
      for (var i = 1; i <= 8; i++)
        entry('임박 $i', deadline: '2026-10-${16 + i}', reasons: interest, published: i >= 6 ? '2026-10-16' : null),
    ];

    Finder freshTitle() => find.widgetWithText(SectionTitle, '새 공고');
    Finder freshMarks() => find.descendant(of: find.byType(Pill), matching: find.text('새 공고'));

    /// 말풍선의 화면 읽기 이름
    String nudge(WidgetTester tester) => tester.getSemantics(find.bySemanticsLabel(RegExp('^오늘의 귀띔'))).label;

    /// [titles]가 화면에서 위에서부터 이 순서로 놓였는지
    void inOrder(WidgetTester tester, List<String> titles) {
      final tops = [for (final t in titles) tester.getTopLeft(findText(t)).dy];
      for (var i = 1; i < tops.length; i++) {
        expect(tops[i], greaterThan(tops[i - 1]), reason: '${titles[i - 1]} → ${titles[i]}');
      }
    }

    test('펼친 홈: 마감 카드에 7일 안 전부, 아래 구역의 같은 공고 줄과 마감 변경 카드는 빼고, 말풍선은 그대로', () {
      final h = buildHomeSections(
        list(eight()),
        [savedOne('저장 변경', deadline: '2026-10-24', was: '2026-10-21')],
        today,
      );
      expect(h.deadlines.map((r) => r.id), ['임박 1', '임박 2', '임박 3', '임박 4', '임박 5']);
      expect(h.moreCount, 4); // 임박 6~8과 저장 변경
      expect(h.fresh.map((r) => r.id), ['임박 6', '임박 7', '임박 8']);
      expect(h.changed.map((s) => s.notice.noticeId), ['저장 변경']);
      final open = h.expanded();
      // 같은 날이면 저장한 공고 먼저(기존 마감순 규칙)
      expect(open.deadlines.map((r) => r.id), [for (var i = 1; i <= 7; i++) '임박 $i', '저장 변경', '임박 8']);
      expect(open.fresh, isEmpty);
      expect(open.changed, isEmpty);
      expect(open.moreCount, 0);
      expect(identical(open.nudge, h.nudge), isTrue);
      expect(open.deadlines.where((r) => r.fresh).map((r) => r.id), ['임박 6', '임박 7', '임박 8']);
      // 펼칠 것이 없으면 그대로
      final small = buildHomeSections(list(eight().take(5).toList()), const [], today);
      expect(small.moreCount, 0);
      expect(identical(small.expanded(), small), isTrue);
    });

    testWidgets('8건: 접힌 카드 5줄과 3건 더 보기 → 펼치면 8줄 마감순, 새 공고 구역 숨김 → 접으면 복원', (tester) async {
      bigScreen(tester);
      final semantics = tester.ensureSemantics();
      await pumpHome(tester, ListRepo(eight()));
      for (var i = 1; i <= 5; i++) {
        expect(findText('임박 $i'), findsOneWidget);
      }
      expect(find.text('3건 더 보기'), findsOneWidget);
      expect(freshTitle(), findsOneWidget);
      expect(freshMarks(), findsNothing); // 아래 구역(아이콘 줄)에는 표시가 없다
      inOrder(tester, ['임박 5', '3건 더 보기', '새 공고', '임박 6']); // 6~8은 펼침 줄 아래 '새 공고' 구역
      final before = nudge(tester);
      expect(before, contains('새 공고 3건'));

      await tester.tap(find.text('3건 더 보기'));
      await tester.pumpAndSettle();
      expect(freshTitle(), findsNothing);
      expect(freshMarks(), findsNWidgets(3)); // 펼친 마감 줄 6~8에 '새 공고' 표시
      for (var i = 6; i <= 8; i++) {
        expect(findText('임박 $i'), findsOneWidget); // 한 번만
      }
      inOrder(tester, [for (var i = 1; i <= 8; i++) '임박 $i', '접기']);
      expect(nudge(tester), before);

      // 탭을 오가도 펼친 상태는 유지
      await tester.tap(find.descendant(of: find.byType(GwTabBar), matching: find.text('공고')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(GwTabBar), matching: find.text('오늘')));
      await tester.pumpAndSettle();
      expect(find.text('접기'), findsOneWidget);

      await tester.tap(find.text('접기'));
      await tester.pumpAndSettle();
      expect(find.text('3건 더 보기'), findsOneWidget);
      expect(freshTitle(), findsOneWidget);
      expect(freshMarks(), findsNothing);
      inOrder(tester, ['임박 5', '3건 더 보기', '새 공고', '임박 6']);
      expect(nudge(tester), before);
      semantics.dispose();

      // 후보 5건이면 펼침 줄이 없다
      await pumpHome(tester, ListRepo(eight().take(5).toList()));
      expect(find.textContaining('더 보기'), findsNothing);
    });

    testWidgets('펼칠 후보에 마감이 바뀐 저장 공고: 펼치면 줄 메타에 변경 문구, 하단 카드 숨김, 접으면 카드 복원', (tester) async {
      bigScreen(tester);
      final semantics = tester.ensureSemantics();
      await pumpHome(
        tester,
        ListRepo(
          [for (var i = 1; i <= 5; i++) entry('임박 $i', deadline: '2026-10-${17 + i}', reasons: interest)],
          saved: [savedOne('저장 변경', deadline: '2026-10-23', was: '2026-10-20')],
        ),
      );
      expect(find.text('1건 더 보기'), findsOneWidget);
      expect(findTextContaining('저장한 공고의 마감 3일 연장'), findsOneWidget);
      final before = nudge(tester);
      expect(before, contains('마감 변경 1건'));

      await tester.tap(find.text('1건 더 보기'));
      await tester.pumpAndSettle();
      expect(findTextContaining('저장한 공고의 마감 3일 연장'), findsNothing);
      expect(plain(tester, metaOf('저장 변경')), endsWith('마감 3일 연장'));
      expect(nudge(tester), before);

      await tester.tap(find.text('접기'));
      await tester.pumpAndSettle();
      expect(findTextContaining('저장한 공고의 마감 3일 연장'), findsOneWidget);
      expect(findText('저장 변경'), findsNothing);
      expect(nudge(tester), before);
      semantics.dispose();
    });

    testWidgets('공고 줄은 오른쪽 화살표(화면 읽기에서 뺌)가 있는 버튼, 펼침 줄은 가운데 글자와 아래 화살표', (tester) async {
      bigScreen(tester);
      final semantics = tester.ensureSemantics();
      await pumpHome(tester, ListRepo(eight()));
      final arrows = find.descendant(
        of: find.byType(HomeScreen),
        matching: find.descendant(of: find.byType(ExcludeSemantics), matching: find.byIcon(Icons.chevron_right_rounded)),
      );
      expect(arrows, findsNWidgets(8)); // 마감 5 + 새 공고 3
      // 화살표는 줄 오른쪽 끝, 제목보다 오른쪽
      expect(tester.getTopLeft(arrows.first).dx, greaterThan(tester.getTopRight(findText('임박 1')).dx));
      final line = tester.getSemantics(find.ancestor(of: findText('임박 1'), matching: find.byType(InkWell)).first);
      expect(line.flagsCollection.isButton, isTrue);
      final more = find.text('3건 더 보기');
      final moreRow = find.ancestor(of: more, matching: find.byType(Row)).first;
      expect(find.descendant(of: moreRow, matching: find.byIcon(Icons.expand_more_rounded)), findsOneWidget);
      expect(tester.getSize(find.ancestor(of: more, matching: find.byType(InkWell)).first).height, greaterThanOrEqualTo(48));
      semantics.dispose();
    });
  });

  testWidgets('글꼴 2배에서 섹션 제목이 어절 중간에서 끊기지 않고 오른쪽 글이 아랫줄로 간다', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3; // 폭 360
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: gwittimTheme(),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(360, 800), textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: SectionTitle('다가오는 마감', trailing: Text('맞춤 공고 · 앞으로 2주')),
            ),
          ),
        ),
      ),
    );
    final title = tester.getRect(find.text('다가오는 마감'));
    final trailing = tester.getRect(find.text('맞춤 공고 · 앞으로 2주'));
    expect(title.height, lessThan(19 * 2 * 1.6)); // 한 줄
    expect(trailing.top, greaterThanOrEqualTo(title.bottom - 1)); // 아랫줄
  });
}
