import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/api_repository.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/ui/external_search_screen.dart';
import 'package:gwittim/ui/notices_screen.dart';
import 'package:gwittim/ui/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'finders.dart';

// fixtures/valid/external_search_response/found.json, none_found.json 과 같은 모양
const _found = {
  'items': [
    {
      'title': '합성 소프트웨어 공모전',
      'url': 'https://contest.example.invalid/view/1',
      'source_name': '합성 공모전 사이트',
      'deadline': '2026-12-31',
      'reason': '합성 예시입니다. 관심 분야인 소프트웨어 개발과 이어지는 공모전입니다.',
      'verified': true,
      'verdict': 'met',
      'target': '전국 대학생(재학생·휴학생) 누구나',
      'organizer': '합성 주최 기관',
      'read': true,
    },
    {
      'title': '합성 AI 아이디어 해커톤',
      'url': 'https://list.example.invalid/contests',
      'source_name': '합성 목록 사이트',
      'deadline': null,
      'reason': '합성 예시입니다. 온라인으로 참여할 수 있습니다.',
      'verified': true,
      'verdict': 'needs_check',
      'target': '국내 대학생 (만 29세 이하)',
      'organizer': null,
      'read': true,
    },
    {
      'title': '출처에 없는 합성 대회',
      'url': 'https://nowhere.example.invalid/',
      'source_name': 'nowhere.example.invalid',
      'deadline': null,
      'reason': '합성 예시입니다.',
      'verified': false,
      'verdict': null,
      'target': null,
      'organizer': null,
      'read': false,
    },
  ],
  'charged': true,
  'excluded_not_met': 1,
  'searched_at': '2026-11-23T03:00:00Z',
};

const _noneFound = {'items': [], 'charged': false, 'searched_at': '2026-11-23T03:00:00Z'};

/// 보낸 조건을 기록하고, 정해 둔 결과나 오류를 돌려준다.
class _Repo extends SampleNoticeRepository {
  _Repo({this.result, this.failWith}) : super(personalized: true);

  final ExternalSearchResult? result;
  final RepositoryErrorKind? failWith;
  final calls = <Map<String, Object?>>[];

  @override
  Future<ExternalSearchResult> requestExternalSearch({
    required String requestId,
    String? category,
    List<String> interests = const [],
    String? period,
    List<String> regions = const [],
    String query = '',
  }) {
    calls.add({
      'request_id': requestId,
      'category': category,
      'interests': interests,
      'period': period,
      'regions': regions,
      'query': query,
    });
    if (failWith case final kind?) return Future.error(RepositoryException(kind, fromServer: true));
    final r = result;
    if (r != null) return Future.value(r);
    return super.requestExternalSearch(
      requestId: requestId,
      category: category,
      interests: interests,
      period: period,
      regions: regions,
      query: query,
    );
  }
}

Future<void> _open(WidgetTester tester, _Repo repo, {bool consent = true, OpenUrlSpy? spy}) async {
  tester.view.physicalSize = const Size(1600, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(repo.preload);
  if (consent) await repo.grantAgentConsent();
  await tester.pumpWidget(
    MaterialApp(
      theme: gwittimTheme(),
      home: ExternalSearchScreen(
        repository: repo,
        openUrl: (url) async {
          spy?.opened.add(url);
          return true;
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class OpenUrlSpy {
  final opened = <Uri>[];
}

Future<void> _search(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, '찾기 · 크레딧 2개'));
  await tester.pumpAndSettle();
}

void main() {
  group('모델', () {
    test('응답 파싱: 확인된 결과·마감 없음·확인 안 된 결과', () {
      final r = ExternalSearchResult.fromJson(_found);
      expect(r.charged, isTrue);
      expect(r.searchedAt, DateTime.utc(2026, 11, 23, 3));
      expect(r.items, hasLength(3));
      expect(r.items[0].verified, isTrue);
      expect(r.items[0].deadline, '2026-12-31');
      expect(r.items[0].sourceName, '합성 공모전 사이트');
      expect(r.items[1].deadline, isNull);
      expect(r.items[2].verified, isFalse);
      expect(r.items[2].deadline, isNull);
    });

    test('결과 없음: 차감되지 않음', () {
      final r = ExternalSearchResult.fromJson(_noneFound);
      expect(r.items, isEmpty);
      expect(r.charged, isFalse);
    });
  });

  group('API 저장소', () {
    final base = Uri.parse('https://api.example.invalid/');
    final headers = {'content-type': 'application/json; charset=utf-8'};

    ApiNoticeRepository repo(http.Response Function(http.Request) handler, List<http.Request> seen) =>
        ApiNoticeRepository(
          baseUrl: base,
          tokenProvider: ({refresh = false}) async => 'good',
          client: MockClient((req) async {
            seen.add(req);
            return handler(req);
          }),
        );

    test('요청 본문: 빈 조건은 보내지 않고 글은 앞뒤 공백을 떼며 50자를 넘기지 않는다', () async {
      final seen = <http.Request>[];
      final r = repo((_) => http.Response(jsonEncode(_found), 200, headers: headers), seen);

      final result = await r.requestExternalSearch(requestId: 'req-1');
      expect(seen.single.method, 'POST');
      expect(seen.single.url.path, '/v1/external-search');
      expect(jsonDecode(seen.single.body), {'request_id': 'req-1'});
      expect(result.items, hasLength(3));

      await r.requestExternalSearch(
        requestId: 'req-2',
        category: 'contest',
        interests: const ['ai_data'],
        period: 'vacation',
        regions: const ['any'],
        query: '  데이터 분석  ',
      );
      expect(jsonDecode(seen.last.body), {
        'request_id': 'req-2',
        'category': 'contest',
        'interests': ['ai_data'],
        'period': 'vacation',
        'regions': ['any'],
        'query': '데이터 분석',
      });

      await r.requestExternalSearch(requestId: 'req-3', query: '가' * 70);
      expect(((jsonDecode(seen.last.body) as Map)['query'] as String).runes.length, 50);
    });

    test('오류 코드 매핑: 크레딧 부족·동의 없음·진행 중·서버 실패', () async {
      Future<RepositoryException> failWith(int status, String code) async {
        final r = repo(
          (_) => http.Response(
            jsonEncode({
              'error': {'code': code, 'message': '오류'},
            }),
            status,
            headers: headers,
          ),
          [],
        );
        try {
          await r.requestExternalSearch(requestId: 'r');
        } on RepositoryException catch (e) {
          return e;
        }
        fail('예외가 나야 합니다');
      }

      expect((await failWith(402, 'insufficient_credits')).kind, RepositoryErrorKind.insufficientCredits);
      expect((await failWith(403, 'consent_required')).kind, RepositoryErrorKind.consentRequired);
      expect((await failWith(409, 'request_in_progress')).kind, RepositoryErrorKind.requestInProgress);
      final down = await failWith(503, 'unavailable');
      expect(down.kind, RepositoryErrorKind.unavailable);
      expect(down.fromServer, isTrue);
    });
  });

  group('샘플 저장소', () {
    test('2크레딧을 차감하고, 출처 확인 안 된 결과가 하나 든다', () async {
      final repo = SampleNoticeRepository(personalized: true);
      await repo.grantAgentConsent();
      final r = await repo.requestExternalSearch(requestId: 'a');
      expect(r.charged, isTrue);
      expect(r.items.where((i) => !i.verified), hasLength(1));
      expect((await repo.getCredits()).balance, Credits.max - 2);
    });

    test('잔액이 2 미만이면 크레딧 부족', () async {
      final repo = SampleNoticeRepository(personalized: true)..debugSetBalance(1);
      await repo.grantAgentConsent();
      await expectLater(
        repo.requestExternalSearch(requestId: 'a'),
        throwsA(isA<RepositoryException>().having((e) => e.kind, 'kind', RepositoryErrorKind.insufficientCredits)),
      );
      expect((await repo.getCredits()).balance, 1);
    });
  });

  group('화면', () {
    testWidgets('조건 화면: 안내 문장, 개인정보 안내, 버튼 문구', (tester) async {
      await _open(tester, _Repo());
      expect(findText('AI가 웹에서 학생 조건에 맞는 공모전·대외활동을 찾습니다.'), findsOneWidget);
      expect(findText('적은 문장은 AI(DeepSeek)에 보내집니다. 이름·연락처 같은 개인정보는 적지 마십시오.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '찾기 · 크레딧 2개'), findsOneWidget);
      // 묶음 제목과 안내는 한 문단이라 큰 글자에서 안내가 통째로 아랫줄로 간다.
      expect(findText('공고 분류  하나 선택'), findsOneWidget);
      expect(findText('갈 수 있는 지역  여러 개 선택'), findsOneWidget);
    });

    testWidgets('개인정보 안내는 입력 칸 바로 아래에 있다', (tester) async {
      await _open(tester, _Repo());
      final field = tester.getRect(find.byType(TextField));
      final note = tester.getRect(findTextContaining('개인정보는 적지 마십시오'));
      expect(note.top, greaterThanOrEqualTo(field.bottom));
      expect(note.top - field.bottom, lessThan(40));
    });

    testWidgets('한 줄 입력은 50자까지', (tester) async {
      await _open(tester, _Repo());
      expect(tester.widget<TextField>(find.byType(TextField)).maxLength, 50);
      await tester.enterText(find.byType(TextField), '가' * 60);
      await tester.pump();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text.length, 50);
      expect(find.text('50/50'), findsOneWidget);
    });

    testWidgets('결과 카드: 출처 확인 안 됨 표시는 확인 안 된 건에만, 마감 없음은 원문 안내', (tester) async {
      final repo = _Repo(result: ExternalSearchResult.fromJson(_found));
      await _open(tester, repo);
      await _search(tester);

      expect(findTextContaining('원문을 읽어, 응모 대상을 귀띔 규칙으로 판정했습니다'), findsOneWidget);
      expect(findTextContaining('지원 자격이 맞지 않는 1건은 뺐습니다'), findsOneWidget);
      expect(findText('합성 소프트웨어 공모전'), findsOneWidget);
      expect(findText('주최 · 합성 주최 기관   출처 · 합성 공모전 사이트'), findsOneWidget);
      expect(findText('마감 2026-12-31'), findsOneWidget);
      expect(findText('마감 원문 확인'), findsNWidgets(2));
      // 판정 꼬리표: 원문 조건으로 충족 1, 확인 필요 1, 확인 안 된 결과 1
      expect(findText('충족'), findsOneWidget);
      expect(findText('확인 필요'), findsOneWidget);
      expect(findText('응모 대상 · 전국 대학생(재학생·휴학생) 누구나'), findsOneWidget);
      await tester.scrollUntilVisible(findText('출처 확인 안 됨'), 300);
      expect(findText('출처 확인 안 됨'), findsOneWidget);

      // 표시는 확인 안 된 카드 안에만 있다
      final card = find.ancestor(of: findText('출처 확인 안 됨'), matching: find.byType(Material)).first;
      expect(find.descendant(of: card, matching: findText('출처에 없는 합성 대회')), findsOneWidget);
    });

    testWidgets('원문을 못 읽은 결과는 판정 없이 원문 미확인', (tester) async {
      final notRead = ExternalSearchResult.fromJson({
        ..._found,
        'items': [
          {...(_found['items'] as List).first as Map<String, dynamic>, 'verdict': null, 'target': null, 'organizer': null, 'read': false},
        ],
        'excluded_not_met': 0,
      });
      await _open(tester, _Repo(result: notRead));
      await _search(tester);
      expect(findText('원문 미확인'), findsOneWidget);
      expect(findText('충족'), findsNothing);
      expect(findTextContaining('응모 대상 ·'), findsNothing);
      expect(findTextContaining('건은 뺐습니다'), findsNothing);
    });

    testWidgets('모두 확인된 결과에는 출처 확인 안 됨이 없다', (tester) async {
      final verifiedOnly = ExternalSearchResult.fromJson({
        ..._found,
        'items': [(_found['items'] as List).first],
      });
      await _open(tester, _Repo(result: verifiedOnly));
      await _search(tester);
      expect(findText('합성 소프트웨어 공모전'), findsOneWidget);
      expect(findText('출처 확인 안 됨'), findsNothing);
    });

    testWidgets('카드를 누르면 원문을 연다', (tester) async {
      final spy = OpenUrlSpy();
      await _open(tester, _Repo(result: ExternalSearchResult.fromJson(_found)), spy: spy);
      await _search(tester);
      await tester.tap(findText('합성 AI 아이디어 해커톤'));
      await tester.pumpAndSettle();
      expect(spy.opened, [Uri.parse('https://list.example.invalid/contests')]);
    });

    testWidgets('결과가 없으면 차감 없음 안내', (tester) async {
      await _open(tester, _Repo(result: ExternalSearchResult.fromJson(_noneFound)));
      await _search(tester);
      expect(findText('조건에 맞는 공고를 찾지 못했습니다. 크레딧은 차감되지 않았습니다.'), findsOneWidget);
      expect(findText('조건 바꾸기'), findsOneWidget);
    });

    testWidgets('크레딧 부족 안내와 크레딧 보기', (tester) async {
      final repo = _Repo()..debugSetBalance(1);
      await _open(tester, repo);
      await _search(tester);
      expect(findText('크레딧이 부족합니다. 외부 공고 찾기는 2개가 필요합니다.'), findsOneWidget);
      expect(find.text('크레딧 보기'), findsOneWidget);
      expect((await repo.getCredits()).balance, 1);
    });

    testWidgets('서버 실패: 차감 안 됨 안내만 보이고 같은 요청 id로 다시 시도한다', (tester) async {
      final repo = _Repo(failWith: RepositoryErrorKind.unavailable);
      await _open(tester, repo);
      await _search(tester);
      expect(findText('지금은 찾을 수 없습니다. 크레딧은 차감되지 않았습니다.'), findsOneWidget);
      await tester.tap(find.text('다시 시도'));
      await tester.pumpAndSettle();
      expect(repo.calls, hasLength(2));
      expect(repo.calls[1]['request_id'], repo.calls[0]['request_id']);
    });

    testWidgets('조건으로 돌아가 다시 찾으면 새 요청 id', (tester) async {
      final repo = _Repo(result: ExternalSearchResult.fromJson(_found));
      await _open(tester, repo);
      await _search(tester);
      await tester.tap(find.text('조건 바꿔 다시 찾기'));
      await tester.pumpAndSettle();
      await _search(tester);
      expect(repo.calls, hasLength(2));
      expect(repo.calls[1]['request_id'], isNot(repo.calls[0]['request_id']));
    });

    testWidgets('보내는 조건: 내 정보의 관심 분야가 처음 선택되어 있고, 고른 칩과 글만 보낸다', (tester) async {
      final repo = _Repo(result: ExternalSearchResult.fromJson(_found));
      await _open(tester, repo);
      final profile = (await repo.getProfile())!;
      await tester.enterText(find.byType(TextField), '  데이터 분석  ');
      await tester.tap(find.text('방학'));
      await tester.tap(find.text('온라인만'));
      await tester.pump();
      await _search(tester);

      final call = repo.calls.single;
      expect(call['interests'], unorderedEquals(profile.interestIds.take(5)));
      expect(call['period'], 'vacation');
      expect(call['regions'], ['online_only']);
      expect(call['category'], isNull);
      expect(call['query'], '데이터 분석');
    });

    testWidgets('동의가 없으면 동의 화면부터, 동의하지 않으면 요청하지 않는다', (tester) async {
      final repo = _Repo(result: ExternalSearchResult.fromJson(_found));
      await _open(tester, repo, consent: false);
      await _search(tester);
      expect(findText('AI에 보내는 정보'), findsOneWidget);
      await tester.tap(find.text('동의하지 않음'));
      await tester.pumpAndSettle();
      expect(repo.calls, isEmpty);
      expect(find.widgetWithText(FilledButton, '찾기 · 크레딧 2개'), findsOneWidget);
    });
  });

  Future<void> pumpNotices(WidgetTester tester, NoticeRepository repo) async {
    tester.view.physicalSize = const Size(1600, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: gwittimTheme(),
        home: Scaffold(
          body: NoticesScreen(repository: repo, openUrl: (_) async => true, today: DateTime(2026, 10, 30)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('공고 탭 칩 줄 아래 입구를 누르면 찾기 화면이 열린다 (D-049)', (tester) async {
    final repo = _Repo();
    await tester.runAsync(repo.preload);
    await pumpNotices(tester, repo);
    expect(findText('학교 밖 기회 찾기  AI 웹 검색'), findsOneWidget);
    // 칩 줄 바로 아래, 첫 공고 카드보다 위
    expect(
      tester.getTopLeft(findTextContaining('학교 밖 기회 찾기')).dy,
      lessThan(tester.getTopLeft(find.byType(NoticeCard).first).dy),
    );
    await tester.tap(findTextContaining('학교 밖 기회 찾기'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '찾기 · 크레딧 2개'), findsOneWidget);
  });

  testWidgets('공고 탭 검색 결과가 없으면 빈 화면 버튼으로 학교 밖 찾기', (tester) async {
    final repo = _Repo();
    await tester.runAsync(repo.preload);
    await pumpNotices(tester, repo);
    await tester.tap(find.text('검색'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '없는검색어없는검색어');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('찾는 공고가 없습니다'), findsOneWidget);
    expect(findText('학교 밖 기회 찾기  AI 웹 검색'), findsNothing); // 입구는 빈 화면 버튼 하나로
    await tester.tap(find.widgetWithText(TextButton, '학교 밖 기회 찾기'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '찾기 · 크레딧 2개'), findsOneWidget);
  });
}
