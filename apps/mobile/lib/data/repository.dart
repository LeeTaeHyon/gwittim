import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';

/// 앱 데이터 접근 경계 (SPEC §7). 샘플 구현과 실제 구현(W6: Firebase 로그인·서버 API)을 교체한다.
abstract class NoticeRepository {
  Future<RecommendationList> listRecommendations();

  /// 공개된 공고가 없으면 null (not_found)
  Future<Notice?> getNotice(String noticeId);

  /// 카테고리 코드 → 표시 이름
  Future<Map<String, String>> categoryNames();

  /// 프로필이 아직 없으면 null
  Future<UserProfile?> getProfile();
  Future<void> updateProfile(UserProfile profile);

  /// 프로필 입력 선택지: 'majors' / 'interests' / 'roles'
  Future<List<DictionaryItem>> dictionary(String name);

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

/// assets/sample/ 의 합성 자료로 동작한다. 자료는 tools/export_mobile_sample.py 로 만든다.
///
/// 추천 결과는 서버(추천 함수)가 미리 계산한 두 가지 샘플 중 하나를 고른다. 앱은 점수를 계산하지 않는다.
/// 프로필·저장은 메모리에만 둔다 (앱을 다시 켜면 초기화).
class SampleNoticeRepository implements NoticeRepository {
  SampleNoticeRepository({AssetBundle? bundle, this.personalized = true}) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;

  /// true면 합성 프로필이 입력된 상태로 시작한다.
  final bool personalized;

  static const _files = [
    'recommendations_personalized.json',
    'recommendations_latest.json',
    'notices.json',
    'categories.json',
    'majors.json',
    'interests.json',
    'roles.json',
    'profile.json',
  ];

  final Map<String, Map<String, dynamic>> _cache = {};
  UserProfile? _profile;
  bool _profileLoaded = false;
  final Map<String, Map<String, dynamic>> _saved = {};

  /// 샘플 자료를 미리 읽어 둔다. 위젯 테스트에서는 tester.runAsync 안에서 부른다.
  Future<void> preload() async {
    for (final name in _files) {
      await _json(name);
    }
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

  @override
  Future<UserProfile?> getProfile() async {
    if (!_profileLoaded) {
      _profileLoaded = true;
      if (personalized) _profile = UserProfile.fromJson(await _json('profile.json'));
    }
    return _profile;
  }

  @override
  Future<void> updateProfile(UserProfile profile) async {
    _profileLoaded = true;
    _profile = profile;
  }

  @override
  Future<RecommendationList> listRecommendations() async {
    final profile = await getProfile();
    final usePersonal = profile != null && profile.hasPersonalInput;
    return RecommendationList.fromJson(
      await _json(usePersonal ? 'recommendations_personalized.json' : 'recommendations_latest.json'),
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
  Future<Map<String, String>> categoryNames() async => {for (final i in await dictionary('categories')) i.id: i.name};

  @override
  Future<List<DictionaryItem>> dictionary(String name) async {
    final dict = await _json('$name.json');
    return [for (final i in dict['items'] as List) DictionaryItem(i['id'] as String, i['name_ko'] as String)];
  }

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
