import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'repository.dart';

/// 로그인 토큰 공급자 (Firebase Auth ID 토큰). 로그인 전이면 null.
/// [refresh]이면 받아 둔 토큰을 쓰지 않고 새로 받는다.
typedef TokenProvider = Future<String?> Function({bool refresh});

/// 서버 API(backend/api, W13)를 쓰는 실제 Repository.
/// 사용자 ID는 보내지 않는다. 서버가 토큰에서 정한다 (SPEC §5).
class ApiNoticeRepository implements NoticeRepository {
  ApiNoticeRepository({
    required this.baseUrl,
    required this.tokenProvider,
    http.Client? client,
    AssetDictionaries? dictionaries,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client(),
       _dictionaries = dictionaries ?? AssetDictionaries();

  final Uri baseUrl;
  final TokenProvider tokenProvider;
  final Duration timeout;
  final http.Client _client;
  final AssetDictionaries _dictionaries;

  static const _errorKinds = {
    'unauthenticated': RepositoryErrorKind.unauthenticated,
    'permission_denied': RepositoryErrorKind.permissionDenied,
    'invalid_argument': RepositoryErrorKind.invalidArgument,
    'not_found': RepositoryErrorKind.notFound,
    'unavailable': RepositoryErrorKind.unavailable,
  };

  Future<http.Response> _send(String method, String path, {Map<String, dynamic>? body}) async {
    final token = await tokenProvider();
    if (token == null) throw const RepositoryException(RepositoryErrorKind.unauthenticated);
    var response = await _request(method, path, token, body);
    // 기기 시계가 틀리면 만료된 토큰을 아직 쓸 수 있다고 보고 그대로 줄 수 있다.
    // 401이면 토큰을 새로 받아 한 번만 다시 보낸다. 서버는 401일 때 요청을 처리하지 않으므로 저장·삭제도 다시 보내도 된다.
    if (response.statusCode == 401) {
      final fresh = await tokenProvider(refresh: true);
      if (fresh != null && fresh != token) response = await _request(method, path, fresh, body);
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return response;
    throw RepositoryException(_kindOf(response));
  }

  Future<http.Response> _request(String method, String path, String token, Map<String, dynamic>? body) async {
    final request = http.Request(method, baseUrl.resolve(path))
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      return await http.Response.fromStream(await _client.send(request).timeout(timeout));
    } on TimeoutException {
      throw const RepositoryException(RepositoryErrorKind.unavailable);
    } on SocketException {
      throw const RepositoryException(RepositoryErrorKind.unavailable);
    } on http.ClientException {
      throw const RepositoryException(RepositoryErrorKind.unavailable);
    }
  }

  RepositoryErrorKind _kindOf(http.Response response) {
    try {
      final code = (jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>)['error']['code'] as String;
      return _errorKinds[code] ?? RepositoryErrorKind.unavailable;
    } catch (_) {
      return switch (response.statusCode) {
        401 => RepositoryErrorKind.unauthenticated,
        403 => RepositoryErrorKind.permissionDenied,
        404 => RepositoryErrorKind.notFound,
        400 => RepositoryErrorKind.invalidArgument,
        _ => RepositoryErrorKind.unavailable,
      };
    }
  }

  Map<String, dynamic> _json(http.Response r) => jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;

  Future<T?> _orNullIfNotFound<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on RepositoryException catch (e) {
      if (e.kind == RepositoryErrorKind.notFound) return null;
      rethrow;
    }
  }

  /// 서버 최대인 50건을 받는다. 공고 탭·달력·브리핑이 함께 쓴다 (D-026).
  static const recommendationLimit = 50;

  @override
  Future<RecommendationList> listRecommendations() => searchNotices();

  @override
  Future<RecommendationList> searchNotices({String query = '', String? category}) async {
    final path = Uri(
      path: 'v1/recommendations',
      queryParameters: {
        'limit': '$recommendationLimit',
        if (query.trim().isNotEmpty) 'q': query.trim(),
        'category': ?category,
      },
    );
    return RecommendationList.fromJson(_json(await _send('GET', path.toString())));
  }

  @override
  Future<Notice?> getNotice(String noticeId) => _orNullIfNotFound(
    () async => Notice.fromJson(_json(await _send('GET', 'v1/notices/${Uri.encodeComponent(noticeId)}'))),
  );

  @override
  Future<Map<String, String>> categoryNames() => _dictionaries.categoryNames();

  @override
  Future<List<DictionaryItem>> dictionary(String name) => _dictionaries.load(name);

  @override
  Future<Map<String, List<String>>> majorInterests() => _dictionaries.majorInterests();

  @override
  Future<UserProfile?> getProfile() =>
      _orNullIfNotFound(() async => UserProfile.fromJson(_json(await _send('GET', 'v1/profile'))));

  @override
  Future<void> updateProfile(UserProfile profile) async {
    await _send('PUT', 'v1/profile', body: profile.toJson());
  }

  @override
  Future<void> deleteAccountData() async {
    await _send('DELETE', 'v1/profile');
  }

  @override
  Future<List<SavedEntry>> listSaved() async {
    final data = _json(await _send('GET', 'v1/saved'));
    return [
      for (final i in data['items'] as List)
        SavedEntry(
          saved: SavedNotice.fromJson(i['saved'] as Map<String, dynamic>),
          notice: NoticeSummary.fromJson(i['notice'] as Map<String, dynamic>),
        ),
    ];
  }

  @override
  Future<void> saveNotice(String noticeId) async {
    await _send('PUT', 'v1/saved/${Uri.encodeComponent(noticeId)}');
  }

  @override
  Future<void> deleteSaved(String noticeId) async {
    await _send('DELETE', 'v1/saved/${Uri.encodeComponent(noticeId)}');
  }
}
