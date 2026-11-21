import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/api_repository.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _base = Uri.parse('https://api.example.invalid/');
final _headers = {'content-type': 'application/json; charset=utf-8'};

http.Response _error(int status, String code) => http.Response(
  jsonEncode({
    'error': {'code': code, 'message': '오류'},
  }),
  status,
  headers: _headers,
);

const _report = {
  'notice_id': 'n1',
  'report': {'fit': '맞는 점', 'eligibility': '지원 자격', 'todo': '할 일', 'skills': '역량'},
  'expires_at': '2026-12-21T00:00:00Z',
  'from_cache': false,
};

ApiNoticeRepository _repo(http.Response Function(http.Request) handler, {List<http.Request>? seen}) =>
    ApiNoticeRepository(
      baseUrl: _base,
      tokenProvider: ({refresh = false}) async => 'good',
      client: MockClient((req) async {
        seen?.add(req);
        return handler(req);
      }),
    );

void main() {
  test('상세 분석 요청 본문: 공고·요청 id·칩, 빈 질문은 키를 보내지 않는다', () async {
    final seen = <http.Request>[];
    final repo = _repo((_) => http.Response(jsonEncode(_report), 200, headers: _headers), seen: seen);
    final r = await repo.requestAnalysis(
      noticeId: 'n1',
      requestId: 'req-1',
      chips: const AnalysisChips(experience: ['python'], period: 'any'),
    );
    expect(seen.single.method, 'POST');
    expect(seen.single.url.path, '/v1/analysis');
    expect(jsonDecode(seen.single.body), {
      'notice_id': 'n1',
      'request_id': 'req-1',
      'chips': {
        'experience': ['python'],
        'period': 'any',
      },
    });
    expect(r.report.fit, '맞는 점');
    expect(r.fromCache, isFalse);

    await repo.requestAnalysis(noticeId: 'n1', requestId: 'req-2');
    expect((jsonDecode(seen.last.body) as Map)['chips'], isEmpty); // '건너뛰고 분석'은 빈 객체
  });

  test('오류 코드 매핑: 동의 없음·크레딧 부족·진행 중·AI 실패', () async {
    Future<RepositoryException> failWith(http.Response r) async {
      try {
        await _repo((_) => r).requestAnalysis(noticeId: 'n1', requestId: 'r');
      } on RepositoryException catch (e) {
        return e;
      }
      fail('예외가 나야 합니다');
    }

    expect((await failWith(_error(403, 'consent_required'))).kind, RepositoryErrorKind.consentRequired);
    expect((await failWith(_error(402, 'insufficient_credits'))).kind, RepositoryErrorKind.insufficientCredits);
    expect((await failWith(_error(409, 'request_in_progress'))).kind, RepositoryErrorKind.requestInProgress);
    expect((await failWith(_error(404, 'not_found'))).kind, RepositoryErrorKind.notFound);
    final unavailable = await failWith(_error(503, 'unavailable'));
    expect(unavailable.kind, RepositoryErrorKind.unavailable);
    expect(unavailable.fromServer, isTrue); // 서버가 응답한 실패 = 차감되지 않음

    // 코드가 없는 응답은 상태 코드로 구분한다
    expect((await failWith(http.Response('x', 402))).kind, RepositoryErrorKind.insufficientCredits);
    expect((await failWith(http.Response('x', 409))).kind, RepositoryErrorKind.requestInProgress);
  });

  test('연결이 끊기면 unavailable이지만 서버 응답은 아니다', () async {
    final repo = ApiNoticeRepository(
      baseUrl: _base,
      tokenProvider: ({refresh = false}) async => 'good',
      client: MockClient((_) async => throw http.ClientException('x')),
    );
    try {
      await repo.requestAnalysis(noticeId: 'n1', requestId: 'r');
      fail('예외가 나야 합니다');
    } on RepositoryException catch (e) {
      expect(e.kind, RepositoryErrorKind.unavailable);
      expect(e.fromServer, isFalse);
    }
  });

  test('받은 분석 조회는 없으면 null, 크레딧은 잔액·내역을 읽는다', () async {
    final repo = _repo((req) {
      if (req.url.path == '/v1/analysis/n1') {
        return http.Response(jsonEncode({..._report, 'from_cache': true}), 200, headers: _headers);
      }
      if (req.url.path == '/v1/credits') {
        return http.Response(
          jsonEncode({
            'balance': 3,
            'next_refill_at': '2026-11-21T15:00:00Z',
            'entries': [
              {'kind': 'detail_analysis', 'amount': -1, 'at': '2026-11-21T00:42:00Z', 'ref': 'n1'},
              {'kind': 'daily', 'amount': 1, 'at': '2026-11-20T15:00:00Z', 'ref': null},
            ],
          }),
          200,
          headers: _headers,
        );
      }
      return _error(404, 'not_found');
    });
    expect((await repo.getAnalysis('n1'))!.fromCache, isTrue);
    expect(await repo.getAnalysis('missing'), isNull);
    final credits = await repo.getCredits();
    expect(credits.balance, 3);
    expect(credits.nextRefillAt, DateTime.utc(2026, 11, 21, 15));
    expect(credits.entries.map((e) => e.kind), ['detail_analysis', 'daily']);
    expect(credits.entries.first.ref, 'n1');
    expect(credits.analysisReceivedAt('n1'), DateTime.utc(2026, 11, 21, 0, 42));
    expect(credits.analysisReceivedAt('n2'), isNull);
  });

  test('최대 보유면 다음 충전 시각이 null', () async {
    final repo = _repo(
      (_) => http.Response(jsonEncode({'balance': 5, 'next_refill_at': null, 'entries': []}), 200, headers: _headers),
    );
    expect((await repo.getCredits()).nextRefillAt, isNull);
  });

  group('동의 기록은 프로필 PUT으로 보낸다', () {
    final profile = {
      'university_id': 'mjc',
      'major_id': null,
      'grade': 2,
      'enrollment_status': 'enrolled',
      'interest_ids': <String>[],
      'target_role_ids': <String>[],
      'updated_at': '2026-11-21T00:00:00Z',
    };

    test('동의: agent_consent {version, agreed_at(Z)}를 넣는다', () async {
      final seen = <http.Request>[];
      final repo = _repo((req) => http.Response(jsonEncode(profile), 200, headers: _headers), seen: seen);
      await repo.grantAgentConsent();
      final put = seen.firstWhere((r) => r.method == 'PUT');
      final consent = (jsonDecode(put.body) as Map)['agent_consent'] as Map;
      expect(consent['version'], agentConsentVersion);
      expect(consent['agreed_at'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$')));
      expect((jsonDecode(put.body) as Map).containsKey('updated_at'), isFalse);
    });

    test('철회: agent_consent를 뺀 프로필을 보낸다', () async {
      final seen = <http.Request>[];
      final repo = _repo(
        (req) => http.Response(
          jsonEncode({
            ...profile,
            'agent_consent': {'version': agentConsentVersion, 'agreed_at': '2026-11-20T00:00:00Z'},
          }),
          200,
          headers: _headers,
        ),
        seen: seen,
      );
      await repo.withdrawAgentConsent();
      final put = seen.firstWhere((r) => r.method == 'PUT');
      expect((jsonDecode(put.body) as Map).containsKey('agent_consent'), isFalse);
      expect((jsonDecode(put.body) as Map)['grade'], 2);
    });

    test('프로필이 없으면 동의를 남길 수 없다', () async {
      final repo = _repo((_) => _error(404, 'not_found'));
      expect(repo.grantAgentConsent(), throwsA(isA<RepositoryException>()));
    });
  });

  test('동의 버전이 다르면 동의한 것으로 보지 않는다', () {
    final old = UserProfile(
      agentConsent: AgentConsent(version: '2000-01-01', agreedAt: DateTime.utc(2026)),
    );
    expect(old.hasAgentConsent, isFalse);
    expect(const UserProfile().hasAgentConsent, isFalse);
    expect((null as UserProfile?).hasAgentConsent, isFalse);
  });
}
