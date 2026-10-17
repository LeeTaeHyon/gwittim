// 앱 ↔ 서버 계약 확인: 실제 로컬 API 서버(backend.api.local)에 붙는다. 서버가 없으면 건너뛴다.
//   uv run uvicorn backend.api.local:app --port 8765
//   GWITTIM_LIVE_API=http://127.0.0.1:8765/ flutter test test/api_live_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/api_repository.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';

// TestWidgetsFlutterBinding은 실제 HTTP를 막으므로 쓰지 않는다.
void main() {
  final base = Platform.environment['GWITTIM_LIVE_API'];
  final skip = base == null ? 'GWITTIM_LIVE_API 미설정' : false;

  ApiNoticeRepository repo(String token) =>
      ApiNoticeRepository(baseUrl: Uri.parse(base!), tokenProvider: () async => token);

  test('실제 서버 응답을 앱 모델로 읽는다', () async {
    final r = repo('dev-token');
    expect((await r.listRecommendations()).personalized, isFalse); // 프로필 없음 → latest

    await r.updateProfile(
      const UserProfile(
        universityId: 'mjc',
        majorId: 'mjc.computer_engineering',
        grade: 2,
        enrollmentStatus: 'enrolled',
        interestIds: ['ai_data', 'software'],
        targetRoleIds: ['software_developer'],
      ),
    );
    final profile = await r.getProfile();
    expect(profile!.majorId, 'mjc.computer_engineering');

    final list = await r.listRecommendations();
    expect(list.personalized, isTrue);
    expect(list.items.first.notice.noticeId, 'n_synthetic_0004');

    final notice = await r.getNotice('n_synthetic_0004');
    expect(notice!.eligibility.conditions, isNotEmpty);
    expect(await r.getNotice('n_synthetic_0005'), isNull); // review_pending

    await r.saveNotice('n_synthetic_0004');
    await r.saveNotice('n_synthetic_0004'); // 반복 안전
    final saved = await r.listSaved();
    expect(saved.map((e) => e.notice.noticeId), ['n_synthetic_0004']);
    expect(saved.single.deadlineChanged, isFalse);
    await r.deleteSaved('n_synthetic_0004');
    expect(await r.listSaved(), isEmpty);
  }, skip: skip);

  test('잘못된 토큰·잘못된 프로필은 구분된 오류', () async {
    await expectLater(
      repo('wrong').listRecommendations(),
      throwsA(isA<RepositoryException>().having((e) => e.kind, 'kind', RepositoryErrorKind.unauthenticated)),
    );
    await expectLater(
      repo('dev-token').updateProfile(const UserProfile(majorId: 'mjc.no_such_major')),
      throwsA(isA<RepositoryException>().having((e) => e.kind, 'kind', RepositoryErrorKind.invalidArgument)),
    );
  }, skip: skip);
}
