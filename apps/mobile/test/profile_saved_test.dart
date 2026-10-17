import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/main.dart';
import 'package:gwittim/ui/profile_screen.dart';
import 'package:gwittim/ui/saved_screen.dart';

Future<SampleNoticeRepository> loaded(WidgetTester tester, {bool personalized = true}) async {
  final repo = SampleNoticeRepository(personalized: personalized);
  await tester.runAsync(repo.preload);
  return repo;
}

DateInfo day(String d) => DateInfo(date: d, time: null, timezone: null, precision: 'date', evidence: 'e');

SavedEntry entry(String id, {String? deadline, required DateTime savedAt, DateInfo? snapshot}) => SavedEntry(
  saved: SavedNotice(noticeId: id, savedAt: savedAt, savedNoticeVersion: 1, savedDeadlineSnapshot: snapshot),
  notice: NoticeSummary(
    noticeId: id,
    noticeVersion: 1,
    title: id,
    category: 'contest',
    sourceUrl: 'https://example.invalid',
    published: null,
    applicationDeadline: deadline == null ? null : day(deadline),
    deadlineNote: null,
    lifecycleStatus: 'open',
  ),
);

void main() {
  final today = DateTime(2026, 10, 17);

  test('마감일 목록: 마감 빠른 순, 마감 미상은 뒤', () {
    final sorted = sortByDeadline([
      entry('none', savedAt: DateTime(2026, 10, 3)),
      entry('late', deadline: '2026-11-02', savedAt: DateTime(2026, 10, 1)),
      entry('soon', deadline: '2026-10-20', savedAt: DateTime(2026, 10, 2)),
    ]);
    expect([for (final e in sorted) e.notice.noticeId], ['soon', 'late', 'none']);
  });

  test('저장 이후 마감 변경 감지', () {
    final today2 = DateTime(2026, 10, 1);
    expect(entry('a', deadline: '2026-10-30', savedAt: today2, snapshot: day('2026-10-28')).deadlineChanged, isTrue);
    expect(entry('a', deadline: '2026-10-30', savedAt: today2, snapshot: day('2026-10-30')).deadlineChanged, isFalse);
    expect(entry('a', savedAt: today2).deadlineChanged, isFalse);
  });

  testWidgets('프로필을 입력하면 피드가 맞춤 추천으로 바뀐다', (tester) async {
    final repo = await loaded(tester, personalized: false);
    await tester.pumpWidget(GwittimApp(repository: repo, openUrl: (_) async => true, today: today));
    await tester.pumpAndSettle();
    expect(find.text('프로필을 입력하면 맞춤 추천을 받을 수 있어요'), findsOneWidget);

    await tester.tap(find.text('프로필'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('소프트웨어 개발'));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('프로필 저장'),
      200,
      scrollable: find.descendant(of: find.byType(ProfileScreen), matching: find.byType(Scrollable)).first,
    );
    await tester.ensureVisible(find.text('프로필 저장'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('프로필 저장'));
    await tester.pumpAndSettle();

    final profile = await repo.getProfile();
    expect(profile!.universityId, 'mjc');
    expect(profile.interestIds, ['software']);
    expect(profile.majorId, isNull); // 선택하지 않은 항목은 추정하지 않음

    await tester.tap(find.text('추천'));
    await tester.pumpAndSettle();
    expect(find.text('프로필을 입력하면 맞춤 추천을 받을 수 있어요'), findsNothing);
  });

  testWidgets('상세에서 저장 → 저장 탭에 마감 변경 안내 → 저장 취소', (tester) async {
    final repo = await loaded(tester);
    await tester.pumpWidget(GwittimApp(repository: repo, openUrl: (_) async => true, today: today));
    await tester.pumpAndSettle();

    const title = '[합성 샘플] 컴퓨터공학과 프로젝트 발표회 참가자 모집';
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('저장'));
    await tester.pumpAndSettle();
    expect(find.text('저장했어요.'), findsOneWidget);
    expect(find.byTooltip('저장 취소'), findsOneWidget);

    // 저장 이후 공고 마감이 바뀐 상황: 저장 당시 10/28, 최신 10/30
    repo.debugReplaceSavedSnapshot('n_synthetic_0004', {
      'date': '2026-10-28',
      'time': '17:00',
      'timezone': 'Asia/Seoul',
      'precision': 'minute',
      'evidence': '2026. 10. 28.(수) 17:00까지',
    });

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(find.text(title), findsOneWidget);
    expect(find.text('D-13'), findsOneWidget);
    expect(find.textContaining('마감이 바뀌었어요 (저장 당시: 2026년 10월 28일 (수) 17:00)'), findsOneWidget);

    await tester.tap(find.byTooltip('저장 취소'));
    await tester.pumpAndSettle();
    expect(find.textContaining('저장한 공고가 없어요'), findsOneWidget);
  });
}
