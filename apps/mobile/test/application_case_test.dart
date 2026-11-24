// 지원 건 상태·기기 저장·판정 저장 (care-loop-impl-spec §2, D-052)
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/application_case.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';

DateInfo dateOnly(String date) => DateInfo(date: date, time: null, timezone: null, precision: 'date', evidence: date);

DateInfo seoul(String date, String time) =>
    DateInfo(date: date, time: time, timezone: 'Asia/Seoul', precision: 'minute', evidence: '$date $time');

NoticeSummary notice(String id, {DateInfo? deadline, String lifecycle = 'open'}) => NoticeSummary(
  noticeId: id,
  noticeVersion: 1,
  title: '공고 $id',
  category: 'contest',
  sourceUrl: 'https://example.com/$id',
  published: null,
  applicationDeadline: deadline,
  deadlineNote: null,
  lifecycleStatus: lifecycle,
);

RecommendationList recs(Map<String, String> statusById) => RecommendationList(
  mode: 'personalized',
  generatedAt: DateTime(2026, 11, 24),
  items: [
    for (final e in statusById.entries)
      RecommendationEntry(
        recommendation: Recommendation(noticeId: e.key, score: 50, eligibilityStatus: e.value, reasonCodes: const []),
        notice: notice(e.key),
      ),
  ],
);

/// 저장·저장 취소·추천·프로필만 흉내 내는 안쪽 저장소. 나머지는 쓰지 않는다.
class FakeInner implements NoticeRepository {
  RecommendationList list = recs({});
  List<SavedEntry> saved = [];
  UserProfile? profile = const UserProfile(universityId: 'mjc', grade: 2, enrollmentStatus: 'enrolled');
  bool failSave = false;

  @override
  Future<RecommendationList> listRecommendations() async => list;
  @override
  Future<RecommendationList> searchNotices({String query = '', String? category}) async => list;
  @override
  Future<List<SavedEntry>> listSaved() async => saved;
  @override
  Future<void> saveNotice(String noticeId) async {
    if (failSave) throw const RepositoryException(RepositoryErrorKind.unavailable);
  }

  @override
  Future<void> deleteSaved(String noticeId) async {}
  @override
  Future<UserProfile?> getProfile() async => profile;
  @override
  Future<void> updateProfile(UserProfile p) async => profile = p;
  @override
  Future<void> deleteAccountData() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FailingStorage implements CaseStorage {
  @override
  Future<Map<String, ApplicationCase>> load() async => throw StateError('읽기 실패');
  @override
  Future<void> save(Map<String, ApplicationCase> cases) async => throw StateError('쓰기 실패');
}

void main() {
  final now = DateTime(2026, 11, 24, 12);

  group('전이(사용자)', () {
    late ApplicationCaseStore store;
    setUp(() async {
      store = ApplicationCaseStore(storage: MemoryCaseStorage(), now: () => now);
      await store.load();
      await store.recordSaved('a');
    });

    test('저장하면 saved', () => expect(store['a']!.state, CaseState.saved));

    test('saved → 준비 시작 → preparing → 신청함 → applied → 되돌리기 → preparing', () async {
      expect(await store.startPreparing('a'), isTrue);
      expect(store['a']!.state, CaseState.preparing);
      expect(await store.markApplied('a'), isTrue);
      expect(store['a']!.state, CaseState.applied);
      expect(store['a']!.previous, CaseState.preparing);
      expect(await store.undo('a'), isTrue);
      expect(store['a']!.state, CaseState.preparing);
    });

    test('saved → 이번엔 안 함 → 되돌리기 → saved', () async {
      expect(await store.markSkipped('a'), isTrue);
      expect(store['a']!.state, CaseState.skipped);
      expect(await store.undo('a'), isTrue);
      expect(store['a']!.state, CaseState.saved);
    });

    test('preparing → 이번엔 안 함', () async {
      await store.startPreparing('a');
      expect(await store.markSkipped('a'), isTrue);
      expect(store['a']!.state, CaseState.skipped);
    });

    test('허용되지 않는 전이는 바꾸지 않음', () async {
      expect(await store.undo('a'), isFalse); // saved에서 되돌리기 없음
      await store.markApplied('a');
      expect(await store.startPreparing('a'), isFalse);
      expect(await store.markSkipped('a'), isFalse);
      expect(store['a']!.state, CaseState.applied);
      expect(await store.startPreparing('없는 공고'), isFalse);
    });

    test('저장 취소·목록에서 지우기는 기록을 지움', () async {
      await store.forget('a');
      expect(store['a'], isNull);
    });
  });

  group('전이(날짜·공고 변경, 읽을 때 계산)', () {
    ApplicationCase c(CaseState s) => ApplicationCase(noticeId: 'a', state: s, changedAt: now);

    test('마감이 지나면 missed, 늦춰지면 저절로 되살아남', () {
      final passed = notice('a', deadline: dateOnly('2026-11-23'));
      expect(effectiveState(c(CaseState.preparing), passed, now), CaseState.missed);
      final extended = notice('a', deadline: dateOnly('2026-11-30'));
      expect(effectiveState(c(CaseState.preparing), extended, now), CaseState.preparing);
    });

    test('마감이 null이면 missed가 되지 않음', () {
      expect(effectiveState(c(CaseState.saved), notice('a'), DateTime(2030)), CaseState.saved);
    });

    test('closed → 모집 끝남, open으로 돌아오면 되살아남', () {
      final closed = notice('a', deadline: dateOnly('2026-12-31'), lifecycle: 'closed');
      expect(effectiveState(c(CaseState.saved), closed, now), CaseState.closed);
      expect(effectiveState(c(CaseState.saved), notice('a', deadline: dateOnly('2026-12-31')), now), CaseState.saved);
    });

    test('마감이 지난 뒤 closed면 closed', () {
      final closed = notice('a', deadline: dateOnly('2026-11-01'), lifecycle: 'closed');
      expect(effectiveState(c(CaseState.saved), closed, now), CaseState.closed);
    });

    test('removed는 어떤 상태든 삭제됨', () {
      final removed = notice('a', lifecycle: 'removed');
      for (final s in [CaseState.saved, CaseState.preparing, CaseState.applied, CaseState.skipped]) {
        expect(effectiveState(c(s), removed, now), CaseState.removed);
      }
    });

    test('신청함·안 함은 마감이 지나거나 closed여도 그대로', () {
      final passedClosed = notice('a', deadline: dateOnly('2026-11-01'), lifecycle: 'closed');
      expect(effectiveState(c(CaseState.applied), passedClosed, now), CaseState.applied);
      expect(effectiveState(c(CaseState.skipped), passedClosed, now), CaseState.skipped);
    });

    test('10:00 마감(Asia/Seoul)은 09:59 아직, 10:00부터 지남', () {
      final d = seoul('2026-12-01', '10:00');
      expect(deadlinePassed(d, DateTime.utc(2026, 12, 1, 0, 59)), isFalse); // 한국 09:59
      expect(deadlinePassed(d, DateTime.utc(2026, 12, 1, 1, 0)), isTrue); // 한국 10:00
    });

    test('시간대 없는 시각·날짜만 마감은 다음 날 0시(기기 시각)에 지남', () {
      final noTz = DateInfo(date: '2026-11-30', time: '18:00', timezone: null, precision: 'minute', evidence: 'x');
      expect(deadlinePassed(noTz, DateTime(2026, 11, 30, 23, 59)), isFalse);
      expect(deadlinePassed(noTz, DateTime(2026, 12, 1)), isTrue);
      expect(deadlinePassed(dateOnly('2026-11-30'), DateTime(2026, 11, 30, 23, 59)), isFalse);
      expect(deadlinePassed(dateOnly('2026-11-30'), DateTime(2026, 12, 1)), isTrue);
    });
  });

  group('기기 저장', () {
    test('저장한 기록을 다시 읽음', () async {
      final storage = MemoryCaseStorage();
      final a = ApplicationCaseStore(storage: storage, now: () => now);
      await a.load();
      await a.recordSaved('a', eligibilityStatus: 'needs_check');
      await a.startPreparing('a');
      await a.markDeadlineSeen('a', seoul('2026-12-01', '10:00'));
      await a.markEmphasized(['a'], now);
      await a.flushed;

      final b = ApplicationCaseStore(storage: storage, now: () => now);
      await b.load();
      final c = b['a']!;
      expect(c.state, CaseState.preparing);
      expect(c.previous, CaseState.saved);
      expect(c.seenDeadline, '2026-12-01 10:00');
      expect(c.emphasizedOn, '2026-11-24');
      expect(b.emphasizedOn('a', now), isTrue);
      expect(c.eligibilityStatus, 'needs_check');
      expect(c.eligibilityAt, now);
    });

    test('읽기·쓰기가 실패해도 멈추지 않고, 이번 실행 동안은 기억함', () async {
      final store = ApplicationCaseStore(storage: FailingStorage(), now: () => now);
      await store.load();
      expect(store.all, isEmpty);
      await store.recordSaved('a');
      expect(store['a']!.state, CaseState.saved);
      await store.clearAll();
      expect(store.all, isEmpty);
    });

    test('앱 본체가 사라진 뒤(탈퇴 직후)에 지워도 오류 없음', () async {
      final store = ApplicationCaseStore(storage: MemoryCaseStorage(), now: () => now);
      await store.recordSaved('a');
      store.dispose();
      await store.clearAll();
      expect(store.all, isEmpty);
    });

    test('알 수 없는 상태 값은 버림', () {
      expect(ApplicationCase.fromJson('a', {'state': 'missed', 'changed_at': now.toIso8601String()}), isNull);
      expect(ApplicationCase.fromJson('a', 'x'), isNull);
    });

    test('저장 목록에 없는 공고의 기록은 지움', () async {
      final store = ApplicationCaseStore(storage: MemoryCaseStorage(), now: () => now);
      await store.recordSaved('a');
      await store.recordSaved('b');
      await store.pruneTo(['b']);
      expect(store['a'], isNull);
      expect(store['b'], isNotNull);
    });
  });

  group('저장소를 거치는 기록과 판정 저장', () {
    late FakeInner inner;
    late ApplicationCaseStore store;
    late CaseTrackingRepository repo;
    setUp(() async {
      inner = FakeInner();
      store = ApplicationCaseStore(storage: MemoryCaseStorage(), now: () => now);
      await store.load();
      repo = CaseTrackingRepository(inner, store);
    });

    test('추천 목록에 있던 공고를 저장하면 그 판정, 없던 공고는 null', () async {
      inner.list = recs({'a': 'needs_check'});
      await repo.listRecommendations();
      await repo.saveNotice('a');
      await repo.saveNotice('b');
      expect(store['a']!.eligibilityStatus, 'needs_check');
      expect(store['a']!.eligibilityAt, now);
      expect(store['b']!.eligibilityStatus, isNull);
      expect(store['b']!.eligibilityAt, isNull);
    });

    test('저장이 실패하면 기록을 만들지 않음', () async {
      inner.failSave = true;
      await expectLater(repo.saveNotice('a'), throwsA(isA<RepositoryException>()));
      expect(store['a'], isNull);
    });

    test('저장 취소하면 기록을 지움', () async {
      await repo.saveNotice('a');
      await repo.deleteSaved('a');
      expect(store['a'], isNull);
    });

    test('추천 목록을 받을 때마다 목록에 있는 지원 건만 갱신', () async {
      await repo.saveNotice('a');
      await repo.saveNotice('b');
      inner.list = recs({'a': 'met'});
      await repo.listRecommendations();
      expect(store['a']!.eligibilityStatus, 'met');
      expect(store['b']!.eligibilityStatus, isNull);
      inner.list = recs({'a': 'not_met', 'b': 'needs_check'});
      await repo.searchNotices(query: '공모');
      expect(store['a']!.eligibilityStatus, 'not_met');
      expect(store['b']!.eligibilityStatus, 'needs_check');
    });

    test('프로필(판정에 쓰는 값)이 바뀌면 모두 null로 지우고 새 추천 목록이 다시 채움', () async {
      inner.list = recs({'a': 'met', 'b': 'needs_check'});
      await repo.listRecommendations();
      await repo.saveNotice('a');
      await repo.saveNotice('b');
      await repo.updateProfile(const UserProfile(universityId: 'mjc', grade: 3, enrollmentStatus: 'enrolled'));
      expect(store['a']!.eligibilityStatus, isNull);
      expect(store['b']!.eligibilityStatus, isNull);
      inner.list = recs({'a': 'not_met'});
      await repo.listRecommendations();
      expect(store['a']!.eligibilityStatus, 'not_met');
      expect(store['b']!.eligibilityStatus, isNull);
      // 지운 뒤 저장하면 지운 판정을 다시 쓰지 않는다(목록에서 새로 받은 것만)
      await repo.saveNotice('b');
      expect(store['b']!.eligibilityStatus, isNull);
    });

    test('동의 기록만 바뀐 프로필 저장은 판정을 지우지 않음', () async {
      inner.list = recs({'a': 'needs_check'});
      await repo.listRecommendations();
      await repo.saveNotice('a');
      await repo.grantAgentConsent();
      expect(store['a']!.eligibilityStatus, 'needs_check');
    });

    test('저장 목록을 받으면 없는 공고의 기록을 지움', () async {
      await repo.saveNotice('a');
      inner.saved = [];
      await repo.listSaved();
      expect(store['a'], isNull);
    });

    test('탈퇴(서버 데이터 삭제)하면 모두 지움', () async {
      await repo.saveNotice('a');
      await repo.deleteAccountData();
      expect(store.all, isEmpty);
    });
  });
}
