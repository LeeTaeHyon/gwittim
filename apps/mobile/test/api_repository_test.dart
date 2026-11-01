import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/api_repository.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _base = Uri.parse('https://api.example.invalid/');

String _asset(String path) => File(path).readAsStringSync();

/// 계약 샘플을 그대로 돌려주는 가짜 서버
http.Response _route(http.Request req) {
  final json = {'content-type': 'application/json; charset=utf-8'};
  final path = req.url.path;
  if (req.headers['Authorization'] != 'Bearer good') {
    return http.Response(
      jsonEncode({
        'error': {'code': 'unauthenticated', 'message': '다시 로그인해 주세요.'},
      }),
      401,
      headers: json,
    );
  }
  if (path == '/v1/recommendations') {
    return http.Response.bytes(
      utf8.encode(_asset('assets/sample/recommendations_personalized.json')),
      200,
      headers: json,
    );
  }
  if (path == '/v1/notices/n_synthetic_0004') {
    final all = jsonDecode(_asset('assets/sample/notices.json')) as Map<String, dynamic>;
    return http.Response.bytes(utf8.encode(jsonEncode(all['n_synthetic_0004'])), 200, headers: json);
  }
  if (path == '/v1/profile' && req.method == 'GET') {
    return http.Response(
      jsonEncode({
        'error': {'code': 'not_found', 'message': '찾을 수 없어요.'},
      }),
      404,
      headers: json,
    );
  }
  if (path == '/v1/profile' && req.method == 'PUT') {
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    return body.containsKey('user_id')
        ? http.Response('{"error":{"code":"invalid_argument","message":"x"}}', 400, headers: json)
        : http.Response(jsonEncode({...body, 'updated_at': '2026-10-17T03:05:00Z'}), 200, headers: json);
  }
  if (path == '/v1/saved' && req.method == 'GET') {
    final all = jsonDecode(_asset('assets/sample/notices.json')) as Map<String, dynamic>;
    final n = all['n_synthetic_0004'] as Map<String, dynamic>;
    final summary = {
      for (final k in [
        'notice_id',
        'notice_version',
        'title',
        'category',
        'source_url',
        'published',
        'application_deadline',
        'deadline_note',
        'lifecycle_status',
      ])
        k: n[k],
    };
    return http.Response.bytes(
      utf8.encode(
        jsonEncode({
          'items': [
            {
              'saved': {
                'notice_id': 'n_synthetic_0004',
                'saved_at': '2026-10-16T09:00:00Z',
                'saved_notice_version': 1,
                'saved_deadline_snapshot': null,
              },
              'notice': summary,
            },
          ],
          'next_cursor': null,
          'generated_at': '2026-10-17T03:05:00Z',
        }),
      ),
      200,
      headers: json,
    );
  }
  if (path.startsWith('/v1/saved/') && req.method == 'PUT') return http.Response('{}', 200, headers: json);
  if (path.startsWith('/v1/saved/') && req.method == 'DELETE') return http.Response('', 204);
  if (path == '/v1/boom') return http.Response('<html>oops</html>', 502);
  return http.Response(
    jsonEncode({
      'error': {'code': 'not_found', 'message': '찾을 수 없어요.'},
    }),
    404,
    headers: json,
  );
}

ApiNoticeRepository repo({String? token = 'good', http.Client? client}) => ApiNoticeRepository(
  baseUrl: _base,
  tokenProvider: () async => token,
  client: client ?? MockClient((r) async => _route(r)),
);

Matcher throwsKind(RepositoryErrorKind kind) => throwsA(isA<RepositoryException>().having((e) => e.kind, 'kind', kind));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('추천 목록과 공고 상세를 읽고 Bearer 토큰을 보낸다', () async {
    final seen = <String?>[];
    final r = repo(
      client: MockClient((req) async {
        seen.add(req.headers['Authorization']);
        return _route(req);
      }),
    );
    final list = await r.listRecommendations();
    expect(list.personalized, isTrue);
    expect(list.items.first.notice.noticeId, 'n_synthetic_0004');
    expect((await r.getNotice('n_synthetic_0004'))!.summary.title, contains('컴퓨터공학과'));
    expect(seen, everyElement('Bearer good'));
  });

  test('없는 공고·프로필은 null', () async {
    expect(await repo().getNotice('missing'), isNull);
    expect(await repo().getProfile(), isNull);
  });

  test('프로필 저장 본문에는 사용자 ID가 없다', () async {
    late Map<String, dynamic> sent;
    final r = repo(
      client: MockClient((req) async {
        if (req.method == 'PUT') sent = jsonDecode(req.body) as Map<String, dynamic>;
        return _route(req);
      }),
    );
    await r.updateProfile(const UserProfile(universityId: 'mjc', interestIds: ['software']));
    expect(sent.containsKey('user_id'), isFalse);
    expect(sent['interest_ids'], ['software']);
    expect(sent.containsKey('updated_at'), isFalse); // 서버가 정함
  });

  test('탈퇴는 DELETE /v1/profile, 본문 없이 토큰만 보낸다 (D-024)', () async {
    final sent = <http.Request>[];
    final r = repo(
      client: MockClient((req) async {
        sent.add(req);
        return http.Response('', 204);
      }),
    );
    await r.deleteAccountData();
    expect(sent.single.method, 'DELETE');
    expect(sent.single.url.path, '/v1/profile');
    expect(sent.single.headers['Authorization'], 'Bearer good');
    expect(sent.single.body, isEmpty);
  });

  test('저장 목록·저장·취소', () async {
    final r = repo();
    final saved = await r.listSaved();
    expect(saved.single.notice.noticeId, 'n_synthetic_0004');
    expect(saved.single.deadlineChanged, isTrue); // 스냅샷 null → 최신 마감 있음
    await r.saveNotice('n_synthetic_0004');
    await r.deleteSaved('n_synthetic_0004');
  });

  test('오류 코드 매핑: 토큰 없음·잘못된 토큰·HTML 오류·네트워크 오류', () async {
    await expectLater(repo(token: null).listRecommendations(), throwsKind(RepositoryErrorKind.unauthenticated));
    await expectLater(repo(token: 'bad').listRecommendations(), throwsKind(RepositoryErrorKind.unauthenticated));
    final html = ApiNoticeRepository(
      baseUrl: _base.resolve('boom/'),
      tokenProvider: () async => 'good',
      client: MockClient((req) async => http.Response('<html>oops</html>', 502)),
    );
    await expectLater(html.listRecommendations(), throwsKind(RepositoryErrorKind.unavailable));
    final offline = repo(client: MockClient((_) async => throw const SocketException('offline')));
    await expectLater(offline.listRecommendations(), throwsKind(RepositoryErrorKind.unavailable));
  });
}
