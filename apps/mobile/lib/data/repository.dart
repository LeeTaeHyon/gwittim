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

  /// 프로필 입력 선택지: 'majors' / 'interests' / 'roles'
  Future<List<DictionaryItem>> dictionary(String name);

  /// 학과 → 졸업생이 많이 가는 관심 분야 (D-020). 프로필 입력 화면의 참고용
  Future<Map<String, List<String>>> majorInterests();

  Future<List<SavedEntry>> listSaved();

  /// 반복 요청 안전
  Future<void> saveNotice(String noticeId);

  /// 반복 요청 안전
  Future<void> deleteSaved(String noticeId);
}

/// API 오류 코드(contracts/api_error.schema.json)와 같은 구분. 화면에는 사용자용 문구만 보여준다.
enum RepositoryErrorKind { unauthenticated, permissionDenied, invalidArgument, notFound, unavailable }

class RepositoryException implements Exception {
  const RepositoryException(this.kind);

  final RepositoryErrorKind kind;

  @override
  String toString() => 'RepositoryException(${kind.name})';
}

/// 공통 사전(contracts/dictionaries 사본, assets/dictionaries/). 샘플·실제 구현이 함께 쓴다.
class AssetDictionaries {
  AssetDictionaries({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;
  final Map<String, List<DictionaryItem>> _cache = {};

  static const names = ['categories', 'majors', 'interests', 'roles', 'universities'];

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
        for (final i in dict['items'] as List) DictionaryItem(i['id'] as String, i['name_ko'] as String),
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
  SampleNoticeRepository({AssetBundle? bundle, this.personalized = true})
    : _bundle = bundle ?? rootBundle,
      _dictionaries = AssetDictionaries(bundle: bundle);

  final AssetBundle _bundle;
  final AssetDictionaries _dictionaries;

  /// true면 합성 프로필이 입력된 상태로 시작한다.
  final bool personalized;

  static const _files = [
    'recommendations_personalized.json',
    'recommendations_latest.json',
    'notices.json',
    'profile.json',
  ];

  final Map<String, Map<String, dynamic>> _cache = {};
  Future<UserProfile?>? _profile;
  final Map<String, Map<String, dynamic>> _saved = {};

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
      return _cache[name] = jsonDecode(await _bundle.loadString('assets/sample/$name')) as Map<String, dynamic>;
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
