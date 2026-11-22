import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';

/// 앱 데이터 접근 경계 (SPEC §7). 샘플 구현과 실제 구현(W6: Firebase 로그인·서버 API)을 교체한다.
abstract class NoticeRepository {
  Future<RecommendationList> listRecommendations();

  /// 공고 탭 검색·분류 칩 (D-026). 추천 후보 전체에서 제목·요약에 [query]가 든 공고, [category] 분류만. 순서는 추천순
  Future<RecommendationList> searchNotices({String query = '', String? category});

  /// 공개된 공고가 없으면 null (not_found)
  Future<Notice?> getNotice(String noticeId);

  /// 카테고리 코드 → 표시 이름
  Future<Map<String, String>> categoryNames();

  /// 프로필이 아직 없으면 null
  Future<UserProfile?> getProfile();
  Future<void> updateProfile(UserProfile profile);

  /// 탈퇴: 서버의 프로필·저장을 지운다. 공개 공고는 남는다. 반복 요청 안전 (D-024)
  Future<void> deleteAccountData();

  /// 프로필 입력 선택지: 'majors' / 'interests' / 'roles'
  Future<List<DictionaryItem>> dictionary(String name);

  /// 학과 → 졸업생이 많이 가는 관심 분야 (D-020). 프로필 입력 화면의 참고용
  Future<Map<String, List<String>>> majorInterests();

  Future<List<SavedEntry>> listSaved();

  /// 반복 요청 안전
  Future<void> saveNotice(String noticeId);

  /// 반복 요청 안전
  Future<void> deleteSaved(String noticeId);

  /// AI 상세 분석 (docs/agent-privacy-spec.md §5·§10). 서버가 분석이 성공했을 때만 크레딧 1개를 차감한다.
  /// [requestId]는 요청마다 새로 만들고 재시도 때만 같은 값을 쓴다(같은 id로 두 번 차감하지 않음).
  /// 오류: consentRequired, insufficientCredits, requestInProgress, notFound, unavailable(차감 안 됨)
  Future<AnalysisResponse> requestAnalysis({
    required String noticeId,
    required String requestId,
    AnalysisChips chips = const AnalysisChips(),
  });

  /// 받은 분석(저장본). 없으면 null. 크레딧을 쓰지 않는다.
  Future<AnalysisResponse?> getAnalysis(String noticeId);

  /// 크레딧 잔액과 최근 90일 사용 내역. 앱은 읽기만 한다.
  Future<Credits> getCredits();
}

/// 동의 기록은 프로필 PUT으로 저장한다(별도 경로 없음). 저장소 구현이 달라도 같은 흐름을 쓴다.
extension AgentConsentActions on NoticeRepository {
  /// 지금 문구([agentConsentVersion])에 동의한 기록을 남긴다. 프로필이 없으면 [RepositoryErrorKind.notFound].
  /// agreed_at은 서버가 서버 시각으로 덮어쓴다.
  Future<void> grantAgentConsent() async {
    final profile = await getProfile();
    if (profile == null) throw const RepositoryException(RepositoryErrorKind.notFound);
    await updateProfile(
      profile.withAgentConsent(AgentConsent(version: agentConsentVersion, agreedAt: DateTime.now().toUtc())),
    );
  }

  /// 동의를 철회한다. 서버가 받은 분석도 지운다.
  Future<void> withdrawAgentConsent() async {
    final profile = await getProfile();
    if (profile == null) return;
    await updateProfile(profile.withAgentConsent(null));
  }
}

/// API 오류 코드(contracts/api_error.schema.json)와 같은 구분. 화면에는 사용자용 문구만 보여준다.
enum RepositoryErrorKind {
  unauthenticated,
  permissionDenied,
  invalidArgument,
  notFound,
  unavailable,

  /// 상세 분석 경로만: 크레딧 부족 / 같은 요청 id 진행 중 / AI 전송 동의 없음
  insufficientCredits,
  requestInProgress,
  consentRequired,
}

class RepositoryException implements Exception {
  const RepositoryException(this.kind, {this.fromServer = false});

  final RepositoryErrorKind kind;

  /// 서버가 응답한 오류인지. false면 연결·시간 초과처럼 서버에 닿았는지 알 수 없는 경우다.
  /// 상세 분석의 unavailable은 서버가 응답했을 때만 크레딧이 차감되지 않았다고 말할 수 있다.
  final bool fromServer;

  @override
  String toString() => 'RepositoryException(${kind.name})';
}

/// 공통 사전(contracts/dictionaries 사본, assets/dictionaries/). 샘플·실제 구현이 함께 쓴다.
class AssetDictionaries {
  AssetDictionaries({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;
  final Map<String, List<DictionaryItem>> _cache = {};

  static const names = [
    'categories',
    'majors',
    'interests',
    'roles',
    'universities',
    'experience_chips',
    'period_chips',
    'region_chips',
  ];

  Future<void> preload() async {
    for (final name in names) {
      await load(name);
    }
    await majorInterests();
  }

  Future<List<DictionaryItem>> load(String name) async {
    final cached = _cache[name];
    if (cached != null) return cached;
    try {
      final dict = jsonDecode(await _bundle.loadString('assets/dictionaries/$name.json')) as Map<String, dynamic>;
      return _cache[name] = [
        for (final i in dict['items'] as List)
          DictionaryItem(i['id'] as String, i['name_ko'] as String, universityId: i['university_id'] as String?),
      ];
    } on FlutterError {
      throw const RepositoryException(RepositoryErrorKind.unavailable);
    }
  }

  Future<Map<String, String>> categoryNames() async => {for (final i in await load('categories')) i.id: i.name};

  Map<String, List<String>>? _majorInterests;

  /// 학과 졸업생 진로 통계(contracts/stats/major_prior.json 사본, assets/stats/, D-020).
  /// 학과 코드 → 많이 가는 관심 분야 코드 (확률 높은 순 3개). 읽지 못하면 빈 표.
  /// 프로필 입력 화면에 보여 주는 데만 쓰고, 프로필에 자동으로 넣지 않는다.
  Future<Map<String, List<String>>> majorInterests() async {
    final cached = _majorInterests;
    if (cached != null) return cached;
    try {
      final data = jsonDecode(await _bundle.loadString('assets/stats/major_prior.json')) as Map<String, dynamic>;
      return _majorInterests = {
        for (final MapEntry(:key, :value) in (data['majors'] as Map<String, dynamic>).entries)
          key:
              ((value['interests'] as Map<String, dynamic>).entries.toList()
                    ..sort((a, b) => (b.value as num).compareTo(a.value as num)))
                  .take(3)
                  .map((e) => e.key)
                  .toList(),
      };
    } on FlutterError {
      return const {};
    }
  }
}

/// assets/sample/ 의 합성 자료로 동작한다. 자료는 tools/export_mobile_sample.py 로 만든다.
///
/// 추천 결과는 서버(추천 함수)가 미리 계산한 두 가지 샘플 중 하나를 고른다. 앱은 점수를 계산하지 않는다.
/// 프로필·저장은 메모리에만 둔다 (앱을 다시 켜면 초기화).
class SampleNoticeRepository implements NoticeRepository {
  SampleNoticeRepository({
    AssetBundle? bundle,
    this.personalized = true,
    this.today,
    this.analysisDelay = Duration.zero,
  })
    : _bundle = bundle ?? rootBundle,
      _dictionaries = AssetDictionaries(bundle: bundle);

  final AssetBundle _bundle;
  final AssetDictionaries _dictionaries;

  /// true면 합성 프로필이 입력된 상태로 시작한다.
  final bool personalized;

  /// 있으면 샘플의 기준일([sampleBaseDay])이 이 날이 되도록 모든 날짜를 같은 날 수만큼 옮긴다.
  /// 언제 켜도 오늘 마감·새 공고·D-day가 같은 모습으로 보인다. 테스트는 비워 두고 원래 날짜를 쓴다.
  final DateTime? today;

  /// 샘플 자료가 '오늘'로 보이게 만든 날: 발표회가 오늘 마감, 경진대회 D-3, 알림톡 공고는 어제 게시.
  static final sampleBaseDay = DateTime.utc(2026, 10, 30);

  static const _files = [
    'recommendations_personalized.json',
    'recommendations_latest.json',
    'notices.json',
    'profile.json',
  ];

  final Map<String, Map<String, dynamic>> _cache = {};
  Future<UserProfile?>? _profile;
  final Map<String, Map<String, dynamic>> _saved = {};

  // 상세 분석·크레딧은 메모리에만 둔다. 서버 규칙(가입 5, 성공해야 차감, 같은 요청 id 한 번만 차감)을 단순하게 흉내 낸다.
  int _balance = Credits.max;
  late final List<CreditEntry> _ledger = [CreditEntry(kind: 'signup', amount: 5, at: DateTime.now().toUtc(), ref: null)];
  final Map<String, AnalysisResponse> _byRequest = {};
  final Map<String, AnalysisResponse> _byInput = {};
  final Map<String, AnalysisResponse> _latest = {};

  /// 분석에 걸리는 시간 흉내. 기다리는 화면을 확인할 때 쓴다.
  final Duration analysisDelay;

  /// 테스트용: 다음 분석 요청 하나를 AI 실패(unavailable)로 만든다. 크레딧은 차감되지 않는다.
  @visibleForTesting
  bool failNextAnalysis = false;

  /// 테스트용: 잔액을 바꾼다.
  @visibleForTesting
  void debugSetBalance(int value) => _balance = value;

  /// 샘플 자료를 미리 읽어 둔다. 위젯 테스트에서는 tester.runAsync 안에서 부른다.
  Future<void> preload() async {
    for (final name in _files) {
      await _json(name);
    }
    await _dictionaries.preload();
  }

  Future<Map<String, dynamic>> _json(String name) async {
    final cached = _cache[name];
    if (cached != null) return cached;
    try {
      final data = jsonDecode(await _bundle.loadString('assets/sample/$name')) as Map<String, dynamic>;
      final t = today;
      if (t == null) return _cache[name] = data;
      final days = DateTime.utc(t.year, t.month, t.day).difference(sampleBaseDay).inDays;
      return _cache[name] = shiftSampleDates(data, days) as Map<String, dynamic>;
    } on FlutterError {
      throw const RepositoryException(RepositoryErrorKind.unavailable);
    }
  }

  /// 피드와 프로필 탭이 동시에 불러도 같은 결과를 받도록 한 번만 읽는다.
  @override
  Future<UserProfile?> getProfile() =>
      _profile ??= personalized ? _json('profile.json').then(UserProfile.fromJson) : Future<UserProfile?>.value(null);

  @override
  Future<void> updateProfile(UserProfile profile) async {
    _profile = Future.value(profile);
    // 서버와 같게: 동의 기록이 빠지면 받은 분석도 지운다.
    if (profile.agentConsent == null) _clearAnalyses();
  }

  @override
  Future<void> deleteAccountData() async {
    _profile = Future<UserProfile?>.value(null);
    _saved.clear();
    _clearAnalyses();
  }

  void _clearAnalyses() {
    _byRequest.clear();
    _byInput.clear();
    _latest.clear();
  }

  @override
  Future<AnalysisResponse> requestAnalysis({
    required String noticeId,
    required String requestId,
    AnalysisChips chips = const AnalysisChips(),
  }) async {
    if (!(await getProfile()).hasAgentConsent) {
      throw const RepositoryException(RepositoryErrorKind.consentRequired, fromServer: true);
    }
    if (await _publishedNotice(noticeId) == null) {
      throw const RepositoryException(RepositoryErrorKind.notFound, fromServer: true);
    }
    final again = _byRequest[requestId];
    if (again != null) return again; // 같은 요청 id는 다시 차감하지 않는다
    if (_balance < 1) throw const RepositoryException(RepositoryErrorKind.insufficientCredits, fromServer: true);
    if (analysisDelay > Duration.zero) await Future<void>.delayed(analysisDelay);
    if (failNextAnalysis) {
      failNextAnalysis = false;
      throw const RepositoryException(RepositoryErrorKind.unavailable, fromServer: true);
    }
    // 저장본이 있는 같은 공고·같은 입력은 차감하되 AI를 부르지 않는다 (명세 §10.3)
    final key = '$noticeId|${jsonEncode(chips.toJson())}';
    final stored = _byInput[key];
    final now = DateTime.now().toUtc();
    final response = AnalysisResponse(
      noticeId: noticeId,
      report:
          stored?.report ??
          const AnalysisReport(
            fit: '- 샘플 분석입니다. 실제 분석은 서버에서 만듭니다.\n- 관심 분야와 공고 내용이 겹치는지 비교합니다.',
            eligibility: '- 공고에 적힌 지원 자격을 정리합니다.\n- 확인하지 못한 조건은 직접 확인해야 합니다.',
            todo: '- 지원서 준비\n- 제출 마감 확인',
            skills: '- 문제 해결\n- 팀 프로젝트 경험',
          ),
      expiresAt: now.add(const Duration(days: 30)),
      fromCache: stored != null,
    );
    _balance -= 1;
    _ledger.insert(0, CreditEntry(kind: 'detail_analysis', amount: -1, at: now, ref: noticeId));
    _byRequest[requestId] = response;
    _byInput[key] = response;
    _latest[noticeId] = AnalysisResponse(
      noticeId: noticeId,
      report: response.report,
      expiresAt: response.expiresAt,
      fromCache: true,
    );
    return response;
  }

  @override
  Future<AnalysisResponse?> getAnalysis(String noticeId) async => _latest[noticeId];

  @override
  Future<Credits> getCredits() async {
    // 다음 충전은 다음 날 0시(KST). 최대 보유면 없다.
    final kst = DateTime.now().toUtc().add(const Duration(hours: 9));
    final next = DateTime.utc(kst.year, kst.month, kst.day + 1).subtract(const Duration(hours: 9));
    return Credits(balance: _balance, nextRefillAt: _balance >= Credits.max ? null : next, entries: List.of(_ledger));
  }

  @override
  Future<RecommendationList> listRecommendations() async {
    final profile = await getProfile();
    final usePersonal = profile != null && profile.hasPersonalInput;
    return RecommendationList.fromJson(
      await _json(usePersonal ? 'recommendations_personalized.json' : 'recommendations_latest.json'),
    );
  }

  /// 샘플은 미리 계산한 추천 목록에서 제목과 분류로만 거른다.
  @override
  Future<RecommendationList> searchNotices({String query = '', String? category}) async {
    final list = await listRecommendations();
    final q = query.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    return RecommendationList(
      mode: list.mode,
      generatedAt: list.generatedAt,
      items: [
        for (final e in list.items)
          if ((category == null || e.notice.category == category) &&
              (q.isEmpty || e.notice.title.replaceAll(RegExp(r'\s+'), '').toLowerCase().contains(q)))
            e,
      ],
    );
  }

  Future<Map<String, dynamic>?> _publishedNotice(String noticeId) async {
    final m = (await _json('notices.json'))[noticeId] as Map<String, dynamic>?;
    return m == null || m['publication_status'] != 'published' ? null : m;
  }

  @override
  Future<Notice?> getNotice(String noticeId) async {
    final m = await _publishedNotice(noticeId);
    return m == null ? null : Notice.fromJson(m);
  }

  @override
  Future<Map<String, String>> categoryNames() => _dictionaries.categoryNames();

  @override
  Future<List<DictionaryItem>> dictionary(String name) => _dictionaries.load(name);

  @override
  Future<Map<String, List<String>>> majorInterests() => _dictionaries.majorInterests();

  @override
  Future<List<SavedEntry>> listSaved() async {
    final entries = <SavedEntry>[];
    for (final saved in _saved.values) {
      final m = await _publishedNotice(saved['notice_id'] as String);
      if (m != null) {
        entries.add(SavedEntry(saved: SavedNotice.fromJson(saved), notice: NoticeSummary.fromJson(m)));
      }
    }
    return entries;
  }

  @override
  Future<void> saveNotice(String noticeId) async {
    if (_saved.containsKey(noticeId)) return;
    final m = await _publishedNotice(noticeId);
    if (m == null) throw const RepositoryException(RepositoryErrorKind.notFound);
    _saved[noticeId] = {
      'notice_id': noticeId,
      'saved_at': DateTime.now().toUtc().toIso8601String(),
      'saved_notice_version': m['notice_version'],
      'saved_deadline_snapshot': m['application_deadline'],
    };
  }

  /// 테스트용: 저장 이후 공고 마감이 바뀐 상황을 만든다.
  @visibleForTesting
  void debugReplaceSavedSnapshot(String noticeId, Map<String, dynamic>? snapshot) {
    _saved[noticeId]?['saved_deadline_snapshot'] = snapshot;
  }

  @override
  Future<void> deleteSaved(String noticeId) async {
    _saved.remove(noticeId);
  }
}

final _isoDay = RegExp(r'^(\d{4})-(\d{2})-(\d{2})');
final _koreanDay = RegExp(r'(\d{1,2})월 (\d{1,2})일');

/// 샘플 JSON의 날짜를 [days]일 옮긴다. 'YYYY-MM-DD…' 값은 앞의 날짜만 바꾸고(시각은 그대로),
/// 요약 글 속 'M월 D일'은 기준일의 해로 읽어 같이 옮긴다.
@visibleForTesting
Object? shiftSampleDates(Object? value, int days) {
  if (days == 0) return value;
  return switch (value) {
    Map<String, dynamic> m => <String, dynamic>{for (final e in m.entries) e.key: shiftSampleDates(e.value, days)},
    List<dynamic> l => <dynamic>[for (final v in l) shiftSampleDates(v, days)],
    String s => _shiftText(s, days),
    _ => value,
  };
}

String _shiftText(String s, int days) {
  final iso = _isoDay.firstMatch(s);
  if (iso != null) {
    final d = DateTime.utc(int.parse(iso[1]!), int.parse(iso[2]!), int.parse(iso[3]!)).add(Duration(days: days));
    final head = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return head + s.substring(iso.end);
  }
  return s.replaceAllMapped(_koreanDay, (m) {
    final base = SampleNoticeRepository.sampleBaseDay.year;
    final d = DateTime.utc(base, int.parse(m[1]!), int.parse(m[2]!)).add(Duration(days: days));
    return '${d.month}월 ${d.day}일';
  });
}
