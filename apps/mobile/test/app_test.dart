import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/main.dart';
import 'package:gwittim/ui/briefing_data.dart';
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

NoticeSummary summary(String id, {String? deadline, String? note, String lifecycle = 'open'}) => NoticeSummary(
  noticeId: id,
  noticeVersion: 1,
  title: id,
  category: 'contest',
  sourceUrl: 'https://example.invalid/$id',
  published: null,
  applicationDeadline: deadline == null ? null : day(deadline),
  deadlineNote: note,
  lifecycleStatus: lifecycle,
);

RecommendationEntry entry(
  String id, {
  String? deadline,
  List<String> reasons = const [],
  String status = 'needs_check',
}) => RecommendationEntry(
  recommendation: Recommendation(noticeId: id, score: null, eligibilityStatus: status, reasonCodes: reasons),
  notice: summary(id, deadline: deadline),
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

    test('7일 안 가장 가까운 확정 마감, 관련 공고, 저장 후 마감 변경을 센다', () {
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
      expect(b.urgent?.notice.noticeId, 'b');
      expect(b.related.map((e) => e.notice.noticeId), ['a', 'c']);
      expect(b.changed.single.notice.noticeId, 's');
      expect(deadlineChangeText(b.changed.single), '마감이 3일 늦춰졌어요');
      expect(b.count, 3);
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
      expect(rows.single.label, '공고에서 지원 조건을 찾지 못했어요');
      expect(rows.single.state, CheckState.info);
    });

    test('명시적 제한 없음만 누구나', () {
      expect(checklistRows(notice(unrestricted: true), null, none).single.label, '누구나 지원할 수 있어요');
    });

    test('성적 조건은 직접 확인하고 성적을 받지 않는다고 안내', () {
      final row = checklistRows(notice(unresolved: ['직전 학기 평점 3.0 이상']), null, none).single;
      expect(row.state, CheckState.check);
      expect(row.note, contains('성적을 받지 않아요'));
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
      expect(grouped.note, contains('자동으로 비교하지 못했어요'));
      expect(grouped.count, 3);
      // 성적 조건은 안내가 달라서 따로 남는다 (1개라 묶지 않음)
      expect(rows[2].evidences, ['직전 학기 평점 3.0 이상']);
      expect(rows[2].note, contains('성적을 받지 않아요'));
    });

    test('우대 사항은 지원 자격 뒤에 따로 묶고 확인 필요 수에 넣지 않는다', () {
      final rows = checklistRows(
        notice(
          unresolved: ['해외여행 결격 사유가 없는 자', '남자의 경우 병역필 또는 면제자'],
          preferred: ['외국어 능통자 (토익 850점 이상)', '운전면허 소지자'],
        ),
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
      expect(rows.map((r) => (r.field, r.label)), [('학과', '컴퓨터공학과'), ('학년', '프로필에 없어요')]);
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
    expect(find.text('오늘 챙길 소식 '), findsNothing); // 형광펜 조각은 별도 위젯
    expect(find.textContaining('마감일이 정해지지 않은 공고 1개'), findsOneWidget);

    await tapVisible(tester, find.text(projectTitle).last);

    expect(find.text('지원 전 체크리스트'), findsOneWidget);
    expect(find.text('조건 충족'), findsOneWidget);
    expect(find.text('학과'), findsOneWidget); // 작은 이름표
    expect(find.text('공고에 적힌 말'), findsWidgets); // 근거는 인용 상자로
    expect(find.textContaining('공고 “'), findsNothing);

    // 샘플은 10/17 확인이라 24시간이 지났다 (D-006): 빨간 글자가 아니라 요약 아래 상자로 보인다.
    final stale = find.textContaining('마지막 확인');
    expect(stale, findsOneWidget);
    expect(tester.widget<Text>(stale).style!.color, GwColors.light.body);
    expect(tester.getTopLeft(stale).dy, lessThan(tester.getTopLeft(find.text('지원 전 체크리스트')).dy));
    await tester.scrollUntilVisible(find.text('이래서 추천했어요'), 200);
    await tester.scrollUntilVisible(find.text('10월 30일(금) 17:00 · 신청 마감'), 200);
    expect(find.text('13일 남았어요'), findsOneWidget);

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
    expect(find.text('카카오톡 알림톡으로 받은 공지라 원문 링크가 없어요.'), findsOneWidget);
    expect(find.text('학교 공지에서 보기'), findsNothing);
    expect(find.textContaining('원문 확인 시각'), findsNothing); // 알림톡은 재확인 안내 없음
    expect(opened, isEmpty);
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

    expect(find.text('확인이 필요해요'), findsOneWidget);
    expect(find.text('직접 확인'), findsOneWidget);
    expect(find.text('학교 공지에서 확인하기'), findsOneWidget);
    expect(find.textContaining('첨부파일·이미지에 조건이 더 있을 수 있어요'), findsOneWidget);
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
    expect(find.text('누구나 지원할 수 있어요'), findsOneWidget); // 이 샘플은 명시적 제한 없음
  });

  testWidgets('하루 첫 실행에 브리핑, 같은 날 다시 열면 안 뜬다', (tester) async {
    final store = MemoryBriefingStore();
    final repo = await loaded(tester);
    await tester.pumpWidget(
      GwittimApp(repository: repo, openUrl: (_) async => true, today: today, briefingStore: store),
    );
    await tester.pumpAndSettle();

    expect(find.text('오늘 챙길 소식이'), findsOneWidget);
    expect(find.text('맞춤 공고'), findsOneWidget);
    expect(find.textContaining('합격 가능성을 뜻하지 않아요'), findsOneWidget);
    await tester.tap(find.text('확인했어요'));
    await tester.pumpAndSettle();
    expect(find.text('다가오는 마감'), findsOneWidget);
    expect(find.text('오늘의 귀띔'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      GwittimApp(repository: repo, openUrl: (_) async => true, today: today, briefingStore: store),
    );
    await tester.pumpAndSettle();
    expect(find.text('오늘 챙길 소식이'), findsNothing);
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
    expect(find.text('오늘 챙길 소식이'), findsNothing); // 전할 소식이 없으면 브리핑 없음
    expect(find.text('프로필을 입력하면 맞춤 추천을 받을 수 있어요'), findsOneWidget);
    expect(find.text('최신 공고'), findsOneWidget);
    await tester.tap(find.text('프로필 입력'));
    await tester.pumpAndSettle();
    expect(find.text('아직 입력하지 않았어요'), findsOneWidget); // 내 정보 요약 카드
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
    expect(find.text('새로 불러오지 못했어요. 인터넷 연결을 확인해 주세요.'), findsOneWidget);
    expect(find.text('다가오는 마감'), findsOneWidget); // 보이던 내용은 그대로
  });

  testWidgets('오류 시 상세 없이 안내와 재시도', (tester) async {
    final repo = FailingRepository();
    await tester.pumpWidget(
      GwittimApp(repository: repo, openUrl: (_) async => true, today: today, briefingStore: noBriefing),
    );
    await tester.pumpAndSettle();

    final home = find.byType(HomeScreen);
    expect(find.descendant(of: home, matching: find.text('불러오지 못했어요')), findsOneWidget);
    expect(find.descendant(of: home, matching: find.text('잠시 후 다시 시도해 주세요.')), findsOneWidget);
    expect(find.textContaining('RepositoryException'), findsNothing);
    final before = repo.calls; // 홈과 공고 탭이 한 번씩 부른다
    await tester.tap(find.descendant(of: home, matching: find.text('다시 시도')));
    await tester.pumpAndSettle();
    expect(repo.calls, before + 1);
  });
}
