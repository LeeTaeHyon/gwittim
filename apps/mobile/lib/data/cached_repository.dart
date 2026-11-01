import 'models.dart';
import 'repository.dart';

/// 서버 응답을 탭끼리 나눠 쓰는 저장소 (2026-11-01 성능 점검).
///
/// 앱을 켜면 네 탭이 함께 만들어져 추천 목록·저장 목록·프로필을 각자 요청했다(시작 때 7번).
/// 같은 요청이 진행 중이면 그 응답을 함께 기다리고, 받은 응답은 [maxAge] 동안 다시 쓴다.
/// - 프로필을 고치면 프로필과 추천 목록을, 저장·저장 취소하면 저장 목록을 버린다.
/// - 당겨서 새로 고침은 [forget]으로 모두 버리고 다시 받는다.
/// - 실패한 응답은 남기지 않는다 (다음 요청이 다시 시도).
class CachedNoticeRepository implements NoticeRepository {
  CachedNoticeRepository(this._inner, {this.maxAge = const Duration(minutes: 5), DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final NoticeRepository _inner;
  final Duration maxAge;
  final DateTime Function() _now;

  final _entries = <String, ({Future<Object?> value, DateTime at})>{};

  Future<T> _cached<T>(String key, Future<T> Function() load) {
    final hit = _entries[key];
    if (hit != null && _now().difference(hit.at) < maxAge) return hit.value.then((v) => v as T);
    final value = load();
    _entries[key] = (value: value, at: _now());
    // 오류는 부른 쪽이 받는다. 여기서는 실패한 응답만 지운다
    value.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_entries[key]?.value, value)) _entries.remove(key);
      },
    );
    return value;
  }

  /// 저장해 둔 응답을 모두 버린다. 다음 요청은 서버로 간다.
  void forget() => _entries.clear();

  @override
  Future<RecommendationList> listRecommendations() => _cached('recommendations', _inner.listRecommendations);

  /// 검색은 입력할 때마다 달라서 남기지 않는다. 조건이 없으면 추천 목록과 같다.
  @override
  Future<RecommendationList> searchNotices({String query = '', String? category}) =>
      query.trim().isEmpty && category == null
      ? listRecommendations()
      : _inner.searchNotices(query: query, category: category);

  @override
  Future<Notice?> getNotice(String noticeId) => _cached('notice:$noticeId', () => _inner.getNotice(noticeId));

  @override
  Future<UserProfile?> getProfile() => _cached('profile', _inner.getProfile);

  @override
  Future<List<SavedEntry>> listSaved() => _cached('saved', _inner.listSaved);

  @override
  Future<void> updateProfile(UserProfile profile) async {
    try {
      await _inner.updateProfile(profile);
    } finally {
      _entries
        ..remove('profile')
        ..remove('recommendations');
    }
  }

  @override
  Future<void> saveNotice(String noticeId) async {
    try {
      await _inner.saveNotice(noticeId);
    } finally {
      _entries.remove('saved');
    }
  }

  @override
  Future<void> deleteSaved(String noticeId) async {
    try {
      await _inner.deleteSaved(noticeId);
    } finally {
      _entries.remove('saved');
    }
  }

  /// 탈퇴 (D-024): 프로필·저장이 지워지므로 받아 둔 응답을 모두 버린다.
  @override
  Future<void> deleteAccountData() async {
    try {
      await _inner.deleteAccountData();
    } finally {
      forget();
    }
  }

  // 사전·통계는 앱에 든 파일이라 안쪽 저장소가 이미 한 번만 읽는다.
  @override
  Future<Map<String, String>> categoryNames() => _inner.categoryNames();

  @override
  Future<List<DictionaryItem>> dictionary(String name) => _inner.dictionary(name);

  @override
  Future<Map<String, List<String>>> majorInterests() => _inner.majorInterests();
}

/// 당겨서 새로 고침 전에 부른다. 캐시가 없는 저장소(샘플 등)는 할 일이 없다.
void forgetCached(NoticeRepository repository) {
  if (repository is CachedNoticeRepository) repository.forget();
}
