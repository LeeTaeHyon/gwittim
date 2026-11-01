import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/cached_repository.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/main.dart';
import 'package:gwittim/ui/briefing_data.dart';

/// 샘플 저장소에 요청 횟수를 센다. [failNext]이면 다음 추천 목록 요청이 실패한다.
class CountingRepository extends SampleNoticeRepository {
  final calls = <String, int>{};
  bool failNext = false;
  Completer<void>? gate;

  void _count(String name) => calls[name] = (calls[name] ?? 0) + 1;

  @override
  Future<RecommendationList> listRecommendations() async {
    _count('recommendations');
    await gate?.future;
    if (failNext) {
      failNext = false;
      throw const RepositoryException(RepositoryErrorKind.unavailable);
    }
    return super.listRecommendations();
  }

  @override
  Future<List<SavedEntry>> listSaved() {
    _count('saved');
    return super.listSaved();
  }

  @override
  Future<UserProfile?> getProfile() {
    _count('profile');
    return super.getProfile();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CountingRepository inner;
  late DateTime now;
  late CachedNoticeRepository repo;

  setUp(() async {
    inner = CountingRepository();
    await inner.preload();
    now = DateTime(2026, 11, 1, 9);
    repo = CachedNoticeRepository(inner, now: () => now);
  });

  test('동시에 부른 같은 요청은 한 번만 보낸다', () async {
    inner.gate = Completer();
    final a = repo.listRecommendations();
    final b = repo.listRecommendations();
    inner.gate!.complete();
    expect(identical(await a, await b), isTrue);
    expect(inner.calls['recommendations'], 1);
  });

  test('받은 응답은 5분 동안 다시 쓰고, 지나면 다시 받는다', () async {
    await repo.listRecommendations();
    now = now.add(const Duration(minutes: 4));
    await repo.listRecommendations();
    expect(inner.calls['recommendations'], 1);
    now = now.add(const Duration(minutes: 2));
    await repo.listRecommendations();
    expect(inner.calls['recommendations'], 2);
  });

  test('저장·저장 취소는 저장 목록을, 프로필 저장은 프로필과 추천 목록을 버린다', () async {
    await repo.listSaved();
    await repo.listRecommendations();
    await repo.saveNotice('n_synthetic_0001');
    await repo.listSaved();
    await repo.listRecommendations();
    expect(inner.calls['saved'], 2);
    expect(inner.calls['recommendations'], 1);

    await repo.deleteSaved('n_synthetic_0001');
    await repo.listSaved();
    expect(inner.calls['saved'], 3);

    final profile = await repo.getProfile();
    await repo.getProfile();
    final before = inner.calls['profile']!; // 샘플 저장소는 추천 목록을 만들 때도 프로필을 읽는다
    await repo.updateProfile(profile!);
    await repo.getProfile();
    expect(inner.calls['profile'], before + 1);
    await repo.listRecommendations();
    expect(inner.calls['recommendations'], 2);
  });

  test('실패한 응답은 남기지 않는다', () async {
    inner.failNext = true;
    await expectLater(repo.listRecommendations(), throwsA(isA<RepositoryException>()));
    await repo.listRecommendations();
    expect(inner.calls['recommendations'], 2);
  });

  test('당겨서 새로 고침은 모두 버린다', () async {
    await repo.listRecommendations();
    await repo.listSaved();
    forgetCached(repo);
    await repo.listRecommendations();
    await repo.listSaved();
    expect(inner.calls['recommendations'], 2);
    expect(inner.calls['saved'], 2);
  });

  testWidgets('앱을 켜면 네 탭이 추천 목록·저장 목록을 한 번씩만 받는다', (tester) async {
    final counting = CountingRepository();
    await tester.runAsync(counting.preload);
    await tester.pumpWidget(
      GwittimApp(
        repository: CachedNoticeRepository(counting),
        openUrl: (_) async => true,
        today: DateTime(2026, 10, 17),
        briefingStore: MemoryBriefingStore(alwaysShown: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('나에게 맞는 공고'), findsOneWidget);
    expect(counting.calls['recommendations'], 1);
    expect(counting.calls['saved'], 1);
  });
}
