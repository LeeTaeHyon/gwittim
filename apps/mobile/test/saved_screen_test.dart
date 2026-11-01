import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/ui/saved_screen.dart';
import 'package:gwittim/ui/theme.dart';

import 'finders.dart';

DateInfo day(String d) => DateInfo(date: d, time: null, timezone: null, precision: 'date', evidence: 'e');

SavedEntry saved(
  String id, {
  String? deadline,
  DateInfo? snapshot,
  bool sameSnapshot = true,
  String lifecycle = 'open',
  String? note,
}) {
  final now = deadline == null ? null : day(deadline);
  return SavedEntry(
    saved: SavedNotice(
      noticeId: id,
      savedAt: DateTime(2026, 10, 1),
      savedNoticeVersion: 1,
      savedDeadlineSnapshot: sameSnapshot ? now : snapshot,
    ),
    notice: NoticeSummary(
      noticeId: id,
      noticeVersion: 1,
      title: '공고 $id',
      category: 'contest',
      sourceUrl: 'https://example.invalid/$id',
      published: null,
      applicationDeadline: now,
      deadlineNote: note,
      lifecycleStatus: lifecycle,
    ),
  );
}

/// 저장 목록만 쓰는 가짜 Repository
class SavedRepository implements NoticeRepository {
  @override
  Future<RecommendationList> searchNotices({String query = '', String? category}) => listRecommendations();

  SavedRepository(this.entries);

  final List<SavedEntry> entries;
  final deleted = <String>[];
  final savedAgain = <String>[];

  @override
  Future<List<SavedEntry>> listSaved() async => [
    for (final e in entries)
      if (!deleted.contains(e.notice.noticeId) || savedAgain.contains(e.notice.noticeId)) e,
  ];

  @override
  Future<void> deleteSaved(String noticeId) async => deleted.add(noticeId);

  @override
  Future<void> saveNotice(String noticeId) async => savedAgain.add(noticeId);

  @override
  Future<Map<String, String>> categoryNames() async => {'contest': '공모전'};

  @override
  Future<RecommendationList> listRecommendations() => throw UnimplementedError();

  @override
  Future<Notice?> getNotice(String noticeId) async => null;

  @override
  Future<UserProfile?> getProfile() async => null;

  @override
  Future<void> updateProfile(UserProfile profile) async {}

  @override
  Future<void> deleteAccountData() async {}

  @override
  Future<List<DictionaryItem>> dictionary(String name) async => [];

  @override
  Future<Map<String, List<String>>> majorInterests() async => {};
}

void main() {
  // 2026-10-20은 화요일. 이번 주 10/19(월)~10/25(일), 다음 주 10/26~11/1.
  final today = DateTime(2026, 10, 20);

  group('마감 기준 묶음', () {
    test('이번 주 / 다음 주 / 그 이후 (주는 월요일 시작)', () {
      expect(savedGroupOf(saved('a', deadline: '2026-10-20'), today), SavedGroup.thisWeek);
      expect(savedGroupOf(saved('a', deadline: '2026-10-25'), today), SavedGroup.thisWeek);
      expect(savedGroupOf(saved('a', deadline: '2026-10-26'), today), SavedGroup.nextWeek);
      expect(savedGroupOf(saved('a', deadline: '2026-11-01'), today), SavedGroup.nextWeek);
      expect(savedGroupOf(saved('a', deadline: '2026-11-02'), today), SavedGroup.later);
    });

    test('확정 마감이 없으면 마감일 없음 (선착순 등)', () {
      expect(savedGroupOf(saved('a', note: '선착순 마감'), today), SavedGroup.noDeadline);
      expect(savedGroupOf(saved('a'), today), SavedGroup.noDeadline);
    });

    test('마감된·삭제된·마감일 지난 공고는 지난 공고', () {
      expect(savedGroupOf(saved('a', deadline: '2026-11-20', lifecycle: 'closed'), today), SavedGroup.past);
      expect(savedGroupOf(saved('a', lifecycle: 'removed'), today), SavedGroup.past);
      expect(savedGroupOf(saved('a', deadline: '2026-10-19'), today), SavedGroup.past);
    });

    test('빈 묶음은 빼고 정해진 순서로, 묶음 안은 마감일 순', () {
      final groups = groupSaved([
        saved('past', deadline: '2026-10-10', lifecycle: 'closed'),
        saved('none'),
        saved('later', deadline: '2026-11-20'),
        saved('week2', deadline: '2026-10-24'),
        saved('week1', deadline: '2026-10-21'),
      ], today);
      expect([for (final (g, _) in groups) g], [
        SavedGroup.thisWeek,
        SavedGroup.later,
        SavedGroup.noDeadline,
        SavedGroup.past,
      ]);
      expect([for (final e in groups.first.$2) e.notice.noticeId], ['week1', 'week2']);
    });

    test('마감일이 바뀐 공고는 모집 중인 것만 센다', () {
      final changed = deadlineChangedEntries([
        saved('a', deadline: '2026-10-30', sameSnapshot: false, snapshot: day('2026-10-27')),
        saved('b', deadline: '2026-10-30', lifecycle: 'closed', sameSnapshot: false, snapshot: day('2026-10-27')),
        saved('c', deadline: '2026-10-30'),
      ]);
      expect([for (final e in changed) e.notice.noticeId], ['a']);
    });
  });

  group('저장한 공고 화면', () {
    late SavedRepository repo;

    Future<void> pump(WidgetTester tester, {ThemeMode mode = ThemeMode.light}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: gwittimTheme(),
          darkTheme: gwittimTheme(Brightness.dark),
          themeMode: mode,
          home: Scaffold(
            body: SavedScreen(repository: repo, openUrl: (_) async => true, today: today),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    setUp(() {
      repo = SavedRepository([
        saved('soon', deadline: '2026-10-23', sameSnapshot: false, snapshot: day('2026-10-21')),
        saved('first', note: '선착순 마감 (정원 도달 시 조기 종료)'),
        saved('closed', deadline: '2026-11-02', lifecycle: 'closed'),
        saved('removed', deadline: '2026-11-10', lifecycle: 'removed'),
      ]);
    });

    testWidgets('묶음 제목, 마감 변경 말풍선, 마감·삭제 상태를 보인다', (tester) async {
      await pump(tester);

      expect(find.text('4개'), findsOneWidget);
      expect(find.text('이번 주 마감'), findsOneWidget);
      expect(find.text('마감일 없음'), findsOneWidget);
      expect(find.text('지난 공고'), findsOneWidget);
      expect(find.text('다음 주 마감'), findsNothing); // 빈 묶음은 보이지 않는다

      expect(find.text('마감일이 바뀐 공고 1개'), findsOneWidget);
      expect(findText('공고 soon · 10월 21일(수) → 10월 23일(금)'), findsOneWidget);
      expect(find.text('D-3 · 공모전'), findsOneWidget); // 날짜만 확인된 마감은 시각 없이, 남은 날이 앞
      expect(find.text('선착순 마감 (정원 도달 시 조기 종료) · 공모전'), findsOneWidget);
      expect(find.text('모집 마감 · 공모전'), findsOneWidget);
      expect(find.text('학교 공지에서 삭제됨'), findsOneWidget);
      expect(find.text('목록에서 지우기'), findsOneWidget);
      expect(findText('마감일과 모집 상태는 학교 공지를 다시 확인할 때마다 최신으로 갱신됩니다.'), findsOneWidget);

      // 삭제된 공고에는 북마크 대신 지우기 버튼만 있다
      expect(find.byTooltip('저장 취소'), findsNWidgets(3));
    });

    testWidgets('삭제된 공고를 목록에서 지운다 (delete_saved_notice)', (tester) async {
      await pump(tester);
      await tester.ensureVisible(find.text('목록에서 지우기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('목록에서 지우기'));
      await tester.pumpAndSettle();

      expect(repo.deleted, ['removed']);
      expect(find.text('학교 공지에서 삭제됨'), findsNothing);
      expect(find.text('목록에서 삭제되었습니다.'), findsOneWidget);
      expect(find.text('3개'), findsOneWidget);
    });

    testWidgets('북마크로 저장을 끄고 켜며 짧게 알린다', (tester) async {
      await pump(tester);
      final bookmark = find.descendant(of: find.byKey(const ValueKey('first')), matching: find.byType(IconButton));

      await tester.tap(bookmark);
      await tester.pumpAndSettle();
      expect(repo.deleted, ['first']);
      expect(find.text('저장이 취소되었습니다.'), findsOneWidget);
      expect(findText('공고 first'), findsOneWidget); // 바로 지우지 않고 다시 켤 수 있게 둔다
      expect(find.byTooltip('저장'), findsOneWidget);
      expect(find.text('3개'), findsOneWidget);

      await tester.tap(bookmark);
      await tester.pumpAndSettle();
      expect(repo.savedAgain, ['first']);
      expect(find.text('공고가 저장되었습니다.'), findsOneWidget);
      expect(find.text('4개'), findsOneWidget);
    });

    testWidgets('다크 테마에서도 같은 내용', (tester) async {
      await pump(tester, mode: ThemeMode.dark);
      expect(Theme.of(tester.element(find.byType(SavedScreen))).brightness, Brightness.dark);
      expect(find.text('학교 공지에서 삭제됨'), findsOneWidget);
      final removed = tester.widget<Text>(find.text('학교 공지에서 삭제됨'));
      expect(removed.style?.color, GwColors.dark.urgent);
    });

    testWidgets('저장한 공고가 없으면 안내', (tester) async {
      repo = SavedRepository([]);
      await pump(tester);
      expect(find.textContaining('저장된 공고가 없습니다'), findsOneWidget);
    });
  });
}
