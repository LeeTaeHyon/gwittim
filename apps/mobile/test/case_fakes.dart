// 지원 건 화면 시험에 쓰는 가짜 저장소와 자료 (care-loop-impl-spec §4~§6)
import 'package:gwittim/data/application_case.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';

DateInfo dateOnly(String date) => DateInfo(date: date, time: null, timezone: null, precision: 'date', evidence: '근거 $date');

DateInfo seoul(String date, String time) =>
    DateInfo(date: date, time: time, timezone: 'Asia/Seoul', precision: 'minute', evidence: '근거 $date $time');

NoticeSummary summaryOf(
  String id, {
  DateInfo? deadline,
  String lifecycle = 'open',
  String? sourceUrl = 'https://example.com/n',
  String title = '',
  int version = 1,
}) => NoticeSummary(
  noticeId: id,
  noticeVersion: version,
  title: title.isEmpty ? '공고 $id' : title,
  category: 'contest',
  sourceUrl: sourceUrl,
  published: null,
  applicationDeadline: deadline,
  deadlineNote: null,
  lifecycleStatus: lifecycle,
);

Notice noticeOf(NoticeSummary s, {DateInfo? start, String? applyUrl}) => Notice(
  summary: s,
  description: null,
  applicationStart: start,
  activityPeriod: null,
  eligibility: const Eligibility(
    conditions: [],
    unresolvedEvidence: [],
    extractionComplete: true,
    explicitlyUnrestricted: false,
    unrestrictedEvidence: null,
  ),
  lastVerifiedAt: null,
  applyUrl: applyUrl,
);

SavedEntry savedOf(NoticeSummary s, {DateInfo? snapshot, bool sameSnapshot = true}) => SavedEntry(
  saved: SavedNotice(
    noticeId: s.noticeId,
    savedAt: DateTime(2026, 11, 20),
    savedNoticeVersion: s.noticeVersion,
    savedDeadlineSnapshot: sameSnapshot ? s.applicationDeadline : snapshot,
  ),
  notice: s,
);

ApplicationCase caseOf(
  String id,
  CaseState state, {
  String? eligibility,
  String? seenDeadline,
  DateInfo? start,
  String? applyUrl,
  CaseState? previous,
}) => ApplicationCase(
  noticeId: id,
  state: state,
  previous: previous,
  changedAt: DateTime(2026, 11, 20),
  eligibilityStatus: eligibility,
  seenDeadline: seenDeadline,
  applicationStart: start,
  applyUrl: applyUrl,
  detailVersion: 1,
);

/// 저장 목록·공고·추천 목록을 정해 둔 대로 돌려주는 저장소. 저장·저장 취소는 목록에 반영한다.
class FakeCaseRepository implements NoticeRepository {
  FakeCaseRepository({
    this.recommendations = const [],
    List<SavedEntry> saved = const [],
    Map<String, Notice> notices = const {},
    this.analysis,
  }) : saved = [...saved],
       notices = {...notices};

  List<RecommendationEntry> recommendations;
  List<SavedEntry> saved;
  Map<String, Notice> notices;
  AnalysisResponse? analysis;

  @override
  Future<RecommendationList> listRecommendations() async =>
      RecommendationList(mode: 'personalized', items: recommendations, generatedAt: DateTime(2026, 11, 24));

  @override
  Future<RecommendationList> searchNotices({String query = '', String? category}) => listRecommendations();

  @override
  Future<Notice?> getNotice(String noticeId) async =>
      notices[noticeId] ??
      [
        for (final s in saved)
          if (s.notice.noticeId == noticeId) noticeOf(s.notice),
        for (final e in recommendations)
          if (e.notice.noticeId == noticeId) noticeOf(e.notice),
      ].firstOrNull;

  @override
  Future<List<SavedEntry>> listSaved() async => [...saved];

  @override
  Future<void> saveNotice(String noticeId) async {
    final n = (await getNotice(noticeId))!.summary;
    saved = [...saved, savedOf(n)];
  }

  @override
  Future<void> deleteSaved(String noticeId) async => saved = [
    for (final s in saved)
      if (s.notice.noticeId != noticeId) s,
  ];

  @override
  Future<Map<String, String>> categoryNames() async => {'contest': '공모전'};

  @override
  Future<UserProfile?> getProfile() async => const UserProfile(universityId: 'mjc', grade: 2, enrollmentStatus: 'enrolled');

  @override
  Future<void> updateProfile(UserProfile profile) async {}

  @override
  Future<void> deleteAccountData() async {}

  @override
  Future<List<DictionaryItem>> dictionary(String name) async => const [];

  @override
  Future<Map<String, List<String>>> majorInterests() async => const {};

  @override
  Future<AnalysisResponse> requestAnalysis({
    required String noticeId,
    required String requestId,
    AnalysisChips chips = const AnalysisChips(),
  }) async => throw const RepositoryException(RepositoryErrorKind.unavailable);

  @override
  Future<ExternalSearchResult> requestExternalSearch({
    required String requestId,
    String? category,
    List<String> interests = const [],
    String? period,
    List<String> regions = const [],
    String query = '',
  }) async => throw const RepositoryException(RepositoryErrorKind.unavailable);

  @override
  Future<AnalysisResponse?> getAnalysis(String noticeId) async => analysis;

  @override
  Future<Credits> getCredits() async => const Credits(balance: 3, nextRefillAt: null, entries: []);
}
