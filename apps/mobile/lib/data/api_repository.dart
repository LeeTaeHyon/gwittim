import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'repository.dart';

/// 로그인 토큰 공급자. W6에서 Firebase Auth의 ID 토큰으로 바꾼다. 로그인 전이면 null.
typedef TokenProvider = Future<String?> Function();

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
    final request = http.Request(method, baseUrl.resolve(path))
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(await _client.send(request).timeout(timeout));
    } on TimeoutException {
      throw const RepositoryException(RepositoryErrorKind.unavailable);
    } on SocketException {
      throw const RepositoryException(RepositoryErrorKind.unavailable);
    } on http.ClientException {
      throw const RepositoryException(RepositoryErrorKind.unavailable);
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return response;
    throw RepositoryException(_kindOf(response));
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

  @override
  Future<RecommendationList> listRecommendations() async =>
      RecommendationList.fromJson(_json(await _send('GET', 'v1/recommendations')));

  @override
  Future<Notice?> getNotice(String noticeId) => _orNullIfNotFound(
    () async => Notice.fromJson(_json(await _send('GET', 'v1/notices/${Uri.encodeComponent(noticeId)}'))),
  );

  @override
  Future<Map<String, String>> categoryNames() => _dictionaries.categoryNames();

  @override
  Future<List<DictionaryItem>> dictionary(String name) => _dictionaries.load(name);

  @override
  Future<UserProfile?> getProfile() =>
      _orNullIfNotFound(() async => UserProfile.fromJson(_json(await _send('GET', 'v1/profile'))));

  @override
  Future<void> updateProfile(UserProfile profile) async {
    await _send('PUT', 'v1/profile', body: profile.toJson());
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
