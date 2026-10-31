import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/main.dart';
import 'package:gwittim/ui/briefing_data.dart';
import 'package:gwittim/ui/briefing_screen.dart';
import 'package:gwittim/ui/home_screen.dart';
import 'package:gwittim/ui/notices_screen.dart';
import 'package:gwittim/ui/report_screen.dart';
import 'package:gwittim/ui/theme.dart';

class FailingRepository implements NoticeRepository {
  int calls = 0;

  @override
  Future<RecommendationList> listRecommendations() async {
    calls++;
    throw const RepositoryException(RepositoryErrorKind.unavailable);
  }

  @override
  Future<Notice?> getNotice(String noticeId) async => null;

  @override
  Future<Map<String, String>> categoryNames() async => {};

  @override
  Future<UserProfile?> getProfile() async => null;

  @override
  Future<void> updateProfile(UserProfile profile) async {}

  @override
  Future<List<DictionaryItem>> dictionary(String name) async => [];

  @override
  Future<Map<String, List<String>>> majorInterests() async => {};

  @override
  Future<List<SavedEntry>> listSaved() async => [];

  @override
  Future<void> saveNotice(String noticeId) async {}

  @override
  Future<void> deleteSaved(String noticeId) async {}
}

/// 처음엔 정상, offline을 켜면 목록 요청이 연결 오류로 실패한다 (비행기 모드 새로고침).
class OfflineAfterLoad extends SampleNoticeRepository {
  bool offline = false;

  @override
  Future<RecommendationList> listRecommendations() =>
      offline ? Future.error(const RepositoryException(RepositoryErrorKind.unavailable)) : super.listRecommendations();

  @override
  Future<List<SavedEntry>> listSaved() =>
      offline ? Future.error(const RepositoryException(RepositoryErrorKind.unavailable)) : super.listSaved();
}

/// 에셋 읽기는 실제 비동기라 fake async 밖(runAsync)에서 미리 읽는다.
Future<SampleNoticeRepository> loaded(WidgetTester tester, {bool personalized = true}) async {
  final repo = SampleNoticeRepository(personalized: personalized);
  await tester.runAsync(repo.preload);
  return repo;
}

/// 화면 밖이면 먼저 보이게 한 뒤 누른다.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

const projectTitle = '[합성 샘플] 컴퓨터공학과 프로젝트 발표회 참가자 모집';
const firstComeTitle = '[합성 샘플] 해외 연수 프로그램 모집 (선착순)';

DateInfo day(String date) => DateInfo(date: date, time: null, timezone: null, precision: 'date', evidence: date);

NoticeSummary summary(String id, {String? deadline, String? note, String lifecycle = 'open', String? published}) =>
    NoticeSummary(
      noticeId: id,
      noticeVersion: 1,
      title: id,
      category: 'contest',
      sourceUrl: 'https://example.invalid/$id',
      published: published == null ? null : day(published),
      applicationDeadline: deadline == null ? null : day(deadline),
      deadlineNote: note,
      lifecycleStatus: lifecycle,
    );

RecommendationEntry entry(
  String id, {
  String? deadline,
  List<String> reasons = const [],
  String status = 'needs_check',
  String? published,
}) => RecommendationEntry(
  recommendation: Recommendation(noticeId: id, score: null, eligibilityStatus: status, reasonCodes: reasons),
  notice: summary(id, deadline: deadline, published: published),
);

Notice notice({
  List<EligibilityCondition> conditions = const [],
  List<String> unresolved = const [],
  List<String> preferred = const [],
  bool unrestricted = false,
  bool complete = true,
}) => Notice(
  summary: summary('n'),
  description: null,
  applicationStart: null,
  activityPeriod: null,
  eligibility: Eligibility(
    conditions: conditions,
    unresolvedEvidence: [...unresolved, ...preferred],
    preferredEvidence: preferred,
    extractionComplete: complete,
    explicitlyUnrestricted: unrestricted,
    unrestrictedEvidence: unrestricted ? '누구나' : null,
  ),
  lastVerifiedAt: null,
);

/// 공고 하나만 돌려주는 저장소 (리포트 화면 확인용)
class OneNoticeRepository extends FailingRepository {
  OneNoticeRepository(this.notice);

  final Notice notice;

  @override
  Future<Notice?> getNotice(String noticeId) async => notice;
}

class _RecordingRepository extends OneNoticeRepository {
  _RecordingRepository(super.notice);

  final requested = <String>[];

  @override
  Future<Notice?> getNotice(String noticeId) async {
    requested.add(noticeId);
    return this.notice;
  }
}

void main() {
  final today = DateTime(2026, 10, 17);
  final noBriefing = MemoryBriefingStore(alwaysShown: true);

  group('샘플 Repository', () {
    test('맞춤 추천 목록을 읽는다', () async {
      final list = await SampleNoticeRepository().listRecommendations();
      expect(list.personalized, isTrue);
      expect(list.items, isNotEmpty);
      expect(list.items.first.notice.noticeId, 'n_synthetic_0004');
      expect(list.items.first.recommendation.conditionResults, isNotEmpty);
    });

    test('프로필이 비면 latest 모드이고 점수가 없다', () async {
      final list = await SampleNoticeRepository(personalized: false).listRecommendations();
      expect(list.personalized, isFalse);
      expect(list.items.every((i) => i.recommendation.score == null), isTrue);
    });

    test('동시에 프로필을 읽어도 같은 프로필을 받는다 (피드·프로필 탭 동시 로드)', () async {
      final repo = SampleNoticeRepository();
      final results = await Future.wait([repo.getProfile(), repo.getProfile()]);
      expect(results.map((p) => p?.majorId), ['mjc.computer_engineering', 'mjc.computer_engineering']);
    });

    test('검토 대기 공고는 상세로 보이지 않는다', () async {
      expect(await SampleNoticeRepository().getNotice('n_synthetic_0005'), isNull);
      expect(await SampleNoticeRepository().getNotice('n_synthetic_0001'), isNotNull);
    });
  });

  group('브리핑 내용', () {
    RecommendationList list(List<RecommendationEntry> items, {bool personalized = true}) =>
        RecommendationList(mode: personalized ? 'personalized' : 'latest', items: items, generatedAt: today);

    test('7일 안 가장 가까운 관련 공고의 확정 마감, 저장 후 마감 변경을 센다', () {
      final b = buildBriefing(
        list([
          entry('a', deadline: '2026-10-23', reasons: ['interest_match']),
          entry('b', deadline: '2026-10-20'),
          entry('c', deadline: '2026-11-20', reasons: ['major_match']),
          entry('d'), // 선착순 등 확정 마감 없음
        ]),
        [
          SavedEntry(
            saved: SavedNotice(
              noticeId: 's',
              savedAt: today,
              savedNoticeVersion: 1,
              savedDeadlineSnapshot: day('2026-10-27'),
            ),
            notice: summary('s', deadline: '2026-10-30'),
          ),
        ],
        today,
      );
      expect(b.urgent?.notice.noticeId, 'a'); // b가 더 가깝지만 관련 이유가 없어 마감 임박에 넣지 않는다
      expect(b.fresh, isEmpty); // 게시일 미상은 새 공고로 보지 않는다
      expect(b.changed.single.notice.noticeId, 's');
      expect(deadlineChangeText(b.changed.single), '마감 3일 연장');
      expect(b.count, 2);
    });

    SavedEntry savedOne(String id, {String? deadline, String lifecycle = 'open'}) => SavedEntry(
      saved: SavedNotice(
        noticeId: id,
        savedAt: today,
        savedNoticeVersion: 1,
        savedDeadlineSnapshot: deadline == null ? null : day(deadline),
      ),
      notice: summary(id, deadline: deadline, lifecycle: lifecycle),
    );

    test('조건 소식: 저장 공고 이틀 안 마감, 최근 3일 새 맞춤 공고, 관심 분야 밖 직무 관련 공고', () {
      final b = buildBriefing(
        list([
          entry('저장도 함', deadline: '2026-10-18', reasons: ['interest_match']),
          entry('임박', deadline: '2026-10-21', reasons: ['interest_match']),
          entry('새것', reasons: ['interest_match'], published: '2026-10-15'),
          entry('오래됨', reasons: ['interest_match'], published: '2026-10-14'),
          entry('직무만', reasons: ['role_match']),
          entry('직무+관심', reasons: ['role_match', 'interest_match']),
          entry('새 직무', reasons: ['role_match'], published: '2026-10-17'),
          entry('무관 새것', reasons: ['deadline_timing'], published: '2026-10-17'),
        ]),
        [
          savedOne('저장도 함', deadline: '2026-10-18'),
          savedOne('오늘', deadline: '2026-10-17'),
          savedOne('사흘', deadline: '2026-10-20'),
          savedOne('마감됨', deadline: '2026-10-18', lifecycle: 'closed'),
        ],
        today,
        hasInterests: true,
      );
      expect(b.savedSoon.map((e) => e.notice.noticeId), ['오늘', '저장도 함']); // 가까운 순, 사흘·마감됨은 빠짐
      expect(b.urgent?.notice.noticeId, '임박'); // 위에 이미 나온 저장 공고는 마감 임박에서 뺀다
      expect(b.fresh.map((e) => e.notice.noticeId), ['새것', '새 직무']); // 10/15~17 게시, 관련 공고만
      expect(b.career.map((e) => e.notice.noticeId), ['직무만']); // 새 공고에 나온 것은 겹치지 않게
      expect(b.count, 4);
    });

    test('관심 분야를 입력하지 않았으면 관심 분야 밖 소식은 만들지 않는다', () {
      final b = buildBriefing(
        list([
          entry('직무만', reasons: ['role_match']),
        ]),
        const [],
        today,
      );
      expect(b.career, isEmpty);
      expect(b.isEmpty, isTrue);
    });

    test('학과 통계로만 고른 공고는 마감 임박과 따로, 답한 공고는 빼고 고른다 (D-021)', () {
      final items = [
        entry('통계', deadline: '2026-10-20', reasons: ['major_prior_match']),
        entry('관심', deadline: '2026-10-22', reasons: ['interest_match', 'major_prior_match']),
        entry('통계 가까움', deadline: '2026-10-19', reasons: ['major_prior_match']),
        entry('통계 멂', deadline: '2026-11-20', reasons: ['major_prior_match']),
      ];
      const major = 'mjc.business_administration';
      final b = buildBriefing(list(items), const [], today, majorId: major);
      expect(b.urgent?.notice.noticeId, '관심'); // 학과 통계만 맞는 공고는 마감 임박에 섞지 않는다
      expect(b.majorPick?.notice.noticeId, '통계 가까움');
      expect(b.count, 2);
      expect(deadlineCandidates(list(items)).map((e) => e.notice.noticeId), ['관심']);

      final declined = const MajorPickState().answer('통계 가까움', false, major, today);
      expect(buildBriefing(list(items), const [], today, picks: declined, majorId: major).majorPick?.notice.noticeId, '통계');
      // 홈 다가오는 마감에는 '관심 없어요'라고 한 공고만 빠진다
      expect(majorPicks(list(items), declined, major, today).map((e) => e.notice.noticeId), ['통계', '통계 멂']);
    });

    test('학과 통계 추천: 관심 없음이 세 번 이어지면 30일 쉬고, 학과를 바꾸면 다시 본다 (D-021)', () {
      const major = 'mjc.business_administration';
      var s = const MajorPickState();
      s = s.answer('a', false, major, today).answer('b', false, major, today);
      expect(s.declineStreak, 2);
      s = s.answer('c', true, major, today); // 관심 있어요는 이어진 수를 지운다
      expect(s.declineStreak, 0);
      s = s.answer('d', false, major, today).answer('e', false, major, today).answer('f', false, major, today);
      expect(s.allows(major, today), isFalse);
      expect(s.allows(major, today.add(const Duration(days: 29))), isFalse);
      expect(s.allows(major, today.add(const Duration(days: 30))), isTrue);
      expect(s.allows('mjc.computer_engineering', today), isTrue);
      expect(majorPicks(list([entry('x', reasons: ['major_prior_match'])]), s, major, today), isEmpty);
      expect(s.decided, {'a': false, 'b': false, 'c': true, 'd': false, 'e': false, 'f': false});

      final again = MajorPickState.fromJson(s.toJson());
      expect(again.decided, s.decided);
      expect(again.stoppedOn, s.stoppedOn);
      // 다른 학과로 답하면 이전 답은 버린다
      expect(s.answer('g', false, 'mjc.computer_engineering', today).decided, {'g': false});
    });

    test('마감 후보: 맞춤 추천이면 관련 공고만, 최신 모드면 전부', () {
      final items = [
        entry('a', deadline: '2026-10-20', reasons: ['role_match']),
        entry('b', deadline: '2026-10-18', reasons: ['deadline_timing']),
      ];
      expect(deadlineCandidates(list(items)).map((e) => e.notice.noticeId), ['a']);
      expect(deadlineCandidates(list(items, personalized: false)).map((e) => e.notice.noticeId), ['a', 'b']);
      expect(buildBriefing(list(items, personalized: false), const [], today).urgent?.notice.noticeId, 'b');
    });

    test('지원 자격 확인 이유: 판정하지 못한 조건 이름, 없으면 원문 확인 한 줄', () {
      Recommendation rec(List<ConditionResult> results) => Recommendation(
        noticeId: 'a',
        score: null,
        eligibilityStatus: 'needs_check',
        reasonCodes: const [],
        conditionResults: results,
      );
      expect(
        checkReasons(
          rec(const [
            ConditionResult(field: 'major_id', status: 'met', evidence: '전자공학과'),
            ConditionResult(field: 'grade', status: 'unknown', evidence: '2~3학년', unknownReason: 'profile_missing'),
            ConditionResult(
              field: 'enrollment_status',
              status: 'unknown',
              evidence: '졸업 예정자',
              unknownReason: 'condition_unresolved',
            ),
          ]),
        ),
        ['학년: 프로필에 없어 비교하지 못했습니다', '재학 상태: 원문에서 확인 필요'],
      );
      expect(checkReasons(rec(const [])), ['자동으로 비교하지 못한 조건이 있습니다. 원문에서 확인해 주세요.']);
    });

    test('전할 소식이 없으면 비어 있다 (latest 모드는 관련 공고를 세지 않음)', () {
      final b = buildBriefing(
        list([
          entry('a', deadline: '2026-11-20', reasons: ['interest_match']),
          entry('b'),
        ], personalized: false),
        const [],
        today,
      );
      expect(b.isEmpty, isTrue);
    });

    test('마감된·삭제된 저장 공고의 마감 변경은 알리지 않는다', () {
      final b = buildBriefing(list(const []), [
        SavedEntry(
          saved: SavedNotice(
            noticeId: 's',
            savedAt: today,
            savedNoticeVersion: 1,
            savedDeadlineSnapshot: day('2026-10-10'),
          ),
          notice: summary('s', deadline: '2026-10-12', lifecycle: 'closed'),
        ),
      ], today);
      expect(b.isEmpty, isTrue);
    });
  });

  group('지원 전 체크리스트', () {
    String? none(String _) => null;

    test('조건을 찾지 못하면 제한 없음으로 쓰지 않는다', () {
      final rows = checklistRows(notice(), null, none);
      expect(rows.single.label, '공고에서 지원 조건을 찾지 못했습니다');
      expect(rows.single.state, CheckState.info);
    });

    test('명시적 제한 없음만 누구나', () {
      expect(checklistRows(notice(unrestricted: true), null, none).single.label, '누구나 지원 가능');
    });

    test('성적 조건은 직접 확인하고 성적을 받지 않는다고 안내', () {
      final row = checklistRows(notice(unresolved: ['직전 학기 평점 3.0 이상']), null, none).single;
      expect(row.state, CheckState.check);
      expect(row.note, contains('성적을 받지 않습니다'));
    });

    test('같은 종류 직접 확인 줄은 2개 이상이면 한 줄로 묶는다', () {
      final rows = checklistRows(
        notice(
          conditions: const [EligibilityCondition(field: 'major_id', evidence: '컴퓨터공학과')],
          unresolved: ['직무 관련 자격증 소유자', '직전 학기 평점 3.0 이상', '근무지 인접 거주자 우대', '주말 근무 가능자'],
        ),
        null,
        none,
      );
      expect(rows.map((r) => r.label), ['학과', '직접 확인 3개', '직접 확인']);
      final grouped = rows[1];
      expect(grouped.evidences, ['직무 관련 자격증 소유자', '근무지 인접 거주자 우대', '주말 근무 가능자']);
      expect(grouped.note, contains('자동으로 비교하지 못했습니다'));
      expect(grouped.count, 3);
      // 성적 조건은 안내가 달라서 따로 남는다 (1개라 묶지 않음)
      expect(rows[2].evidences, ['직전 학기 평점 3.0 이상']);
      expect(rows[2].note, contains('성적을 받지 않습니다'));
    });

    test('우대 사항은 지원 자격 뒤에 따로 묶고 확인 필요 수에 넣지 않는다', () {
      final rows = checklistRows(
        notice(unresolved: ['해외여행 결격 사유가 없는 자', '남자의 경우 병역필 또는 면제자'], preferred: ['외국어 능통자 (토익 850점 이상)', '운전면허 소지자']),
        null,
        none,
      );
      expect(rows.map((r) => r.label), ['직접 확인 2개', '우대 사항 2개']);
      expect(rows.last.state, CheckState.info);
      expect(rows.last.evidences, ['외국어 능통자 (토익 850점 이상)', '운전면허 소지자']);
    });

    testWidgets('묶인 근거가 3개를 넘으면 접어 두고 펼칠 수 있다', (tester) async {
      final repo = OneNoticeRepository(notice(unresolved: ['조건 1', '조건 2', '조건 3', '조건 4', '조건 5'], complete: false));
      await tester.pumpWidget(
        MaterialApp(
          theme: gwittimTheme(),
          home: ReportScreen(
            repository: repo,
            noticeId: 'n',
            openUrl: (_) async => true,
            today: today,
            recommendation: const Recommendation(
              noticeId: 'n',
              score: null,
              eligibilityStatus: 'needs_check',
              reasonCodes: ['eligibility_needs_check'],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('직접 확인 5개'), findsOneWidget);
      expect(find.text('5개 조건은 직접 확인해 주세요.'), findsOneWidget); // 개수는 묶기 전 조건 수
      expect(find.text('조건 3'), findsOneWidget);
      expect(find.text('조건 4'), findsNothing);
      await tapVisible(tester, find.text('2개 더 보기'));
      expect(find.text('조건 5'), findsOneWidget);
      await tapVisible(tester, find.text('접기'));
      expect(find.text('조건 5'), findsNothing);
    });

    test('서버 판정을 그대로 쓰고 프로필 값 이름을 붙인다', () {
      final rec = Recommendation(
        noticeId: 'n',
        score: 50,
        eligibilityStatus: 'needs_check',
        reasonCodes: const [],
        conditionResults: const [
          ConditionResult(field: 'major_id', status: 'met', evidence: '컴퓨터공학과'),
          ConditionResult(field: 'grade', status: 'unknown', evidence: '2~3학년', unknownReason: 'profile_missing'),
        ],
      );
      final rows = checklistRows(
        notice(
          conditions: const [EligibilityCondition(field: 'major_id', evidence: '컴퓨터공학과')],
        ),
        rec,
        (f) => f == 'major_id' ? '컴퓨터공학과' : null,
      );
      expect(rows.map((r) => (r.field, r.label)), [('학과', '컴퓨터공학과'), ('학년', '프로필 미입력')]);
      expect(rows.last.state, CheckState.check);
    });

    test('추천 이유 낱말', () {
      final rec = Recommendation(
        noticeId: 'n',
        score: 90,
        eligibilityStatus: 'met',
        reasonCodes: const ['interest_match', 'major_match', 'deadline_timing', 'eligibility_met'],
      );
      final (words, soon) = reasonParts(rec);
      expect(words, ['관심 분야', '전공']);
      expect(soon, isTrue);

      // 학과 통계 (D-020)
      final (prior, _) = reasonParts(
        Recommendation(noticeId: 'n', score: 80, eligibilityStatus: 'met', reasonCodes: const ['major_prior_match']),
      );
      expect(prior, ['학과 졸업생 진로']);
    });
  });

  testWidgets('홈 → 공고 리포트 → 학교 공지 열기', (tester) async {
    tester.view.physicalSize = const Size(800, 2400); // 홈 전체가 한 화면에 보이게
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final opened = <Uri>[];
    await tester.pumpWidget(
      GwittimApp(
        repository: await loaded(tester),
        openUrl: (u) async {
          opened.add(u);
          return true;
        },
        today: today,
        briefingStore: noBriefing,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('다가오는 마감'), findsOneWidget);
    expect(find.byType(NoticeCard), findsNWidgets(3)); // 홈은 상위 3개만, 나머지는 공고 탭
    expect(find.text('전체 보기'), findsOneWidget);
    expect(find.textContaining('합격 가능성'), findsNothing); // 홈 끝 문구는 뺐다 (브리핑·리포트에만)
    expect(find.text(projectTitle), findsNWidgets(2)); // 다가오는 마감 + 나에게 맞는 공고
    expect(find.text('D-13 · 17:00 마감 · 행사'), findsOneWidget); // 다가오는 마감: 남은 날·시각이 앞
    expect(find.text('10월 30일(금) 17:00 마감 · D-13'), findsOneWidget); // 카드: 7일 넘게 남으면 칩 없이 날짜 줄에
    expect(find.text('D-13'), findsNothing);
    expect(find.text('오늘 확인할 공고'), findsOneWidget); // 소식 종류 수는 세지 않는다
    expect(find.text('브리핑 자세히 보기'), findsOneWidget);
    expect(find.text('맞춤 공고 7건'), findsNothing); // 홈 숫자를 다시 세는 배지는 없앴다 (D-018)
    expect(find.textContaining('0건'), findsNothing); // 0건인 칸은 숨긴다
    expect(find.text('맞춤 공고 · 앞으로 2주'), findsOneWidget);
    // 선착순 샘플은 관련 이유가 없는 공고라 다가오는 마감 안내에서도 세지 않는다
    expect(find.textContaining('마감일이 정해지지 않은 공고'), findsNothing);

    await tapVisible(tester, find.text(projectTitle).last);

    expect(find.text('지원 전 체크리스트'), findsOneWidget);
    expect(find.text('조건 충족'), findsOneWidget);
    expect(find.text('학과'), findsOneWidget); // 작은 이름표
    expect(find.text('공고에 적힌 말'), findsWidgets); // 근거는 인용 상자로
    expect(find.textContaining('공고 “'), findsNothing);

    // 샘플은 10/17 확인이라 24시간이 지났다 (D-006): 빨간 글자가 아니라 요약 아래 상자로 보인다.
    final stale = find.textContaining('마지막으로 확인');
    expect(stale, findsOneWidget);
    expect(tester.widget<Text>(stale).style!.color, GwColors.light.body);
    expect(tester.getTopLeft(stale).dy, lessThan(tester.getTopLeft(find.text('지원 전 체크리스트')).dy));
    await tester.scrollUntilVisible(find.text('추천 이유'), 200);
    await tester.scrollUntilVisible(find.text('10월 30일(금) 17:00 · 신청 마감'), 200);
    expect(find.text('D-13'), findsOneWidget);

    await tester.tap(find.text('학교 공지에서 보기'));
    await tester.pumpAndSettle();
    expect(opened.single.toString(), contains('mjc.ac.kr/bbs/data/view.do'));
  });

  testWidgets('알림톡 공고: 원문 링크 대신 안내 문구, 발송 시각 표시 (D-019)', (tester) async {
    final base = notice();
    final kakao = Notice(
      summary: NoticeSummary(
        noticeId: 'n',
        noticeVersion: 1,
        title: '[합성 샘플] 겨울방학 영어 회화 프로그램 안내',
        category: 'global',
        sourceUrl: null,
        published: const DateInfo(
          date: '2026-10-15',
          time: '14:05',
          timezone: 'Asia/Seoul',
          precision: 'minute',
          evidence: '카카오톡 수신 2026-10-15 14:05',
        ),
        applicationDeadline: null,
        deadlineNote: null,
        lifecycleStatus: 'unknown',
      ),
      description: null,
      applicationStart: null,
      activityPeriod: null,
      eligibility: base.eligibility,
      lastVerifiedAt: null,
      sourceId: 'mjc_kakao',
    );
    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: gwittimTheme(),
        home: ReportScreen(
          repository: OneNoticeRepository(kakao),
          noticeId: 'n',
          openUrl: (u) async {
            opened.add(u);
            return true;
          },
          today: today,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('명지전문대 카카오톡 알림톡'), findsOneWidget);
    expect(find.text('10월 15일(목) 14:05 발송'), findsOneWidget);
    expect(find.text('카카오톡 알림톡으로 받은 공지라 원문 링크가 없습니다.'), findsOneWidget);
    expect(find.text('학교 공지에서 보기'), findsNothing);
    expect(find.textContaining('원문 확인 시각'), findsNothing); // 알림톡은 재확인 안내 없음
    expect(opened, isEmpty);
  });

  testWidgets('알림톡 공고: 본문의 신청 사이트 버튼, 관련 학교 공지로 이동 (D-025)', (tester) async {
    final base = notice();
    final kakao = Notice(
      summary: NoticeSummary(
        noticeId: 'n_kakao',
        noticeVersion: 1,
        title: '[합성 샘플] 중간고사 이후 AI 카드뉴스 만들기',
        category: 'contest',
        sourceUrl: null,
        published: null,
        applicationDeadline: null,
        deadlineNote: null,
        lifecycleStatus: 'unknown',
      ),
      description: null,
      applicationStart: null,
      activityPeriod: null,
      eligibility: base.eligibility,
      lastVerifiedAt: null,
      sourceId: 'mjc_kakao',
      applyUrl: 'https://mpu.mjc.ac.kr',
      relatedNotices: const [(noticeId: 'n_board', title: '[합성 샘플] AI 활용 경진대회 참가 안내')],
    );
    final repo = _RecordingRepository(kakao);
    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: gwittimTheme(),
        home: ReportScreen(
          repository: repo,
          noticeId: 'n_kakao',
          openUrl: (u) async {
            opened.add(u);
            return true;
          },
          today: today,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('카카오톡 알림톡으로 받은 공지라 원문 링크가 없습니다.'), findsNothing);
    await tester.tap(find.text('신청 사이트 열기'));
    await tester.pumpAndSettle();
    expect(opened.single.toString(), 'https://mpu.mjc.ac.kr');

    await tester.scrollUntilVisible(find.text('[합성 샘플] AI 활용 경진대회 참가 안내'), 200);
    expect(find.text('관련 학교 공지'), findsOneWidget);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -600)); // 아래 버튼에 가리지 않게 끝까지
    await tester.pumpAndSettle();
    await tester.tap(find.text('[합성 샘플] AI 활용 경진대회 참가 안내'));
    await tester.pumpAndSettle();
    expect(repo.requested.last, 'n_board');
  });

  testWidgets('선착순 공고: 마감 칩 없이 원문 설명, 리포트는 직접 확인과 첨부 안내', (tester) async {
    await tester.pumpWidget(
      GwittimApp(repository: await loaded(tester), openUrl: (_) async => true, today: today, briefingStore: noBriefing),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('공고'));
    await tester.pumpAndSettle();
    final notices = find.descendant(of: find.byType(NoticesScreen), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text(firstComeTitle), 200, scrollable: notices);
    expect(find.text('선착순 마감 (정원 도달 시 조기 종료)'), findsOneWidget);
    await tapVisible(tester, find.text(firstComeTitle));

    expect(find.text('확인 필요'), findsOneWidget);
    expect(find.text('직접 확인'), findsOneWidget);
    expect(find.text('학교 공지에서 확인하기'), findsOneWidget);
    expect(find.textContaining('첨부파일·이미지에 조건이 더 있을 수 있습니다'), findsOneWidget);
    expect(find.textContaining('23:59'), findsNothing);
  });

  testWidgets('조건 미발견 공고는 제한 없음으로 보이지 않는다', (tester) async {
    final repo = await loaded(tester);
    await tester.pumpWidget(
      GwittimApp(repository: repo, openUrl: (_) async => true, today: today, briefingStore: noBriefing),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('공고'));
    await tester.pumpAndSettle();
    final notices = find.descendant(of: find.byType(NoticesScreen), matching: find.byType(Scrollable)).first;
    const title = '[합성 샘플] 학습성과 글쓰기 공모전';
    await tester.scrollUntilVisible(find.text(title), 200, scrollable: notices);
    await tapVisible(tester, find.text(title));
    expect(find.text('누구나 지원 가능'), findsOneWidget); // 이 샘플은 명시적 제한 없음
  });

  testWidgets('브리핑 마감 임박: 날짜와 D-day, 관련 이유, 확인이 필요한 조건 이름', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: gwittimTheme(),
        home: BriefingScreen(
          briefing: Briefing(
            urgent: RecommendationEntry(
              recommendation: const Recommendation(
                noticeId: 'a',
                score: null,
                eligibilityStatus: 'needs_check',
                reasonCodes: ['role_match', 'deadline_timing'],
                conditionResults: [
                  ConditionResult(
                    field: 'grade',
                    status: 'unknown',
                    evidence: '2~3학년',
                    unknownReason: 'profile_missing',
                  ),
                ],
              ),
              notice: summary('데이터 분석 인턴', deadline: '2026-10-19'),
            ),
          ),
          today: today,
          onOpenNotice: (_, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('10월 19일 마감 · D-2'), findsOneWidget);
    expect(find.text('희망 직무 연관 공고'), findsOneWidget);
    expect(find.text('지원 자격 일부 확인 필요'), findsOneWidget);
    expect(find.text('학년: 프로필에 없어 비교하지 못했습니다'), findsOneWidget);
    expect(find.textContaining('일 뒤 마감'), findsNothing);
  });

  testWidgets('브리핑 학과 통계 추천: 안내 표시와 관심 있음·없음 답 (D-021)', (tester) async {
    final answers = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: gwittimTheme(),
        home: BriefingScreen(
          briefing: Briefing(majorPick: entry('경영 사무 인턴', deadline: '2026-10-20', reasons: ['major_prior_match'])),
          today: today,
          onOpenNotice: (_, _) async {},
          onAnswerMajorPick: (_, interested) async {
            answers.add(interested);
            return false;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('학과 통계 추천'), findsNWidgets(2)); // 머리 배지와 카드 표시
    expect(find.textContaining('같은 학과 졸업생이 많이 가는 분야'), findsOneWidget);
    // 아래 고정 버튼에 가리지 않게 끝까지 올린다
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    await tester.tap(find.text('관심 없음'));
    await tester.pumpAndSettle();
    expect(answers, [false]);
    expect(find.text('이 공고는 다시 추천하지 않습니다.'), findsOneWidget);
    expect(find.text('관심 있음'), findsNothing);
  });

  testWidgets('하루 첫 실행에 브리핑, 같은 날 다시 열면 안 뜬다', (tester) async {
    final store = MemoryBriefingStore();
    final repo = await loaded(tester);
    await tester.pumpWidget(
      GwittimApp(repository: repo, openUrl: (_) async => true, today: today, briefingStore: store),
    );
    await tester.pumpAndSettle();

    expect(find.text('주요 소식'), findsOneWidget);
    expect(find.byType(BriefingScreen), findsOneWidget); // 머리는 네이비, 조건 소식만
    expect(find.textContaining('합격 가능성과는 관계없습니다'), findsOneWidget);
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    expect(find.text('다가오는 마감'), findsOneWidget);
    expect(find.text('오늘의 귀띔'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      GwittimApp(repository: repo, openUrl: (_) async => true, today: today, briefingStore: store),
    );
    await tester.pumpAndSettle();
    expect(find.text('주요 소식'), findsNothing);
  });

  testWidgets('프로필이 비면 최신순 안내와 프로필 입력 버튼', (tester) async {
    await tester.pumpWidget(
      GwittimApp(
        repository: await loaded(tester, personalized: false),
        openUrl: (_) async => true,
        today: today,
        briefingStore: MemoryBriefingStore(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('주요 소식'), findsNothing); // 전할 소식이 없으면 브리핑 없음
    expect(find.text('프로필을 입력하면 맞춤 추천을 받을 수 있습니다'), findsOneWidget);
    expect(find.text('최신 공고'), findsOneWidget);
    await tester.tap(find.text('프로필 입력'));
    await tester.pumpAndSettle();
    expect(find.text('입력한 정보 없음'), findsOneWidget); // 내 정보 요약 카드
  });

  testWidgets('새로고침이 실패하면 목록은 두고 연결 안내를 띄운다', (tester) async {
    final repo = OfflineAfterLoad();
    await tester.runAsync(repo.preload);
    await tester.pumpWidget(
      GwittimApp(repository: repo, openUrl: (_) async => true, today: today, briefingStore: noBriefing),
    );
    await tester.pumpAndSettle();
    expect(find.text('다가오는 마감'), findsOneWidget);

    repo.offline = true;
    await tester.fling(find.text('다가오는 마감'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(find.text('새로 불러오지 못했습니다. 인터넷 연결을 확인해 주세요.'), findsOneWidget);
    expect(find.text('다가오는 마감'), findsOneWidget); // 보이던 내용은 그대로
  });

  testWidgets('오류 시 상세 없이 안내와 재시도', (tester) async {
    final repo = FailingRepository();
    await tester.pumpWidget(
      GwittimApp(repository: repo, openUrl: (_) async => true, today: today, briefingStore: noBriefing),
    );
    await tester.pumpAndSettle();

    final home = find.byType(HomeScreen);
    expect(find.descendant(of: home, matching: find.text('불러오기 실패')), findsOneWidget);
    expect(find.descendant(of: home, matching: find.text('잠시 후 다시 시도해 주세요.')), findsOneWidget);
    expect(find.textContaining('RepositoryException'), findsNothing);
    final before = repo.calls; // 홈과 공고 탭이 한 번씩 부른다
    await tester.tap(find.descendant(of: home, matching: find.text('다시 시도')));
    await tester.pumpAndSettle();
    expect(repo.calls, before + 1);
  });
}
