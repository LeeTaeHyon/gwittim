import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/main.dart';

class FailingRepository implements NoticeRepository {
  int calls = 0;

  @override
  Future<RecommendationList> listRecommendations() async {
    calls++;
    throw const RepositoryException(RepositoryErrorKind.unavailable);
  }

  @override
  Future<Notice?> getNotice(String noticeId) async => null;

  @override
  Future<Map<String, String>> categoryNames() async => {};
}

/// 에셋 읽기는 실제 비동기라 fake async 밖(runAsync)에서 미리 읽는다.
Future<SampleNoticeRepository> loaded(WidgetTester tester, {bool personalized = true}) async {
  final repo = SampleNoticeRepository(personalized: personalized);
  await tester.runAsync(repo.preload);
  return repo;
}

void main() {
  final today = DateTime(2026, 10, 17);

  group('샘플 Repository', () {
    test('맞춤 추천 목록을 읽는다', () async {
      final list = await SampleNoticeRepository().listRecommendations();
      expect(list.personalized, isTrue);
      expect(list.items, isNotEmpty);
      expect(list.items.first.notice.noticeId, 'n_synthetic_0004');
    });

    test('프로필이 비면 latest 모드이고 점수가 없다', () async {
      final list = await SampleNoticeRepository(personalized: false).listRecommendations();
      expect(list.personalized, isFalse);
      expect(list.items.every((i) => i.recommendation.score == null), isTrue);
    });

    test('검토 대기 공고는 상세로 보이지 않는다', () async {
      expect(await SampleNoticeRepository().getNotice('n_synthetic_0005'), isNull);
      expect(await SampleNoticeRepository().getNotice('n_synthetic_0001'), isNotNull);
    });
  });

  testWidgets('피드 → 상세 → 원문 열기', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(GwittimApp(
      repository: await loaded(tester),
      openUrl: (u) async {
        opened.add(u);
        return true;
      },
      today: today,
    ));
    await tester.pumpAndSettle();

    expect(find.text('[합성 샘플] 컴퓨터공학과 프로젝트 발표회 참가자 모집'), findsOneWidget);
    expect(find.text('지원 조건 충족'), findsWidgets);
    expect(find.text('D-13'), findsOneWidget); // 마감 10/30

    await tester.tap(find.text('[합성 샘플] 컴퓨터공학과 프로젝트 발표회 참가자 모집'));
    await tester.pumpAndSettle();

    expect(find.text('공고 상세'), findsOneWidget);
    expect(find.text('2026년 10월 30일 (금) 17:00'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('• 전공과 관련된 공고예요'), 200);
    expect(find.text('• 전공과 관련된 공고예요'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('원문 보기'), 200);
    await tester.tap(find.text('원문 보기'));
    await tester.pumpAndSettle();
    expect(opened.single.toString(), contains('mjc.ac.kr/bbs/data/view.do'));
  });

  testWidgets('날짜만 있는 마감은 시각 없이, 조건 미발견·불완전 추출은 안내', (tester) async {
    await tester.pumpWidget(GwittimApp(repository: await loaded(tester), openUrl: (_) async => true, today: today));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('[합성 샘플] 해외 연수 프로그램 모집 (선착순)'), 200);
    expect(find.text('선착순 마감 (정원 도달 시 조기 종료)'), findsOneWidget);
    await tester.tap(find.text('[합성 샘플] 해외 연수 프로그램 모집 (선착순)'));
    await tester.pumpAndSettle();

    expect(find.text('공고에서 지원 조건을 찾지 못했어요. 원문을 확인해 주세요.'), findsOneWidget);
    expect(find.textContaining('첨부파일·이미지에 조건이 더 있을 수 있어요'), findsOneWidget);
    expect(find.textContaining('23:59'), findsNothing);
  });

  testWidgets('프로필이 비면 최신순 안내를 보여준다', (tester) async {
    await tester.pumpWidget(GwittimApp(
      repository: await loaded(tester, personalized: false),
      openUrl: (_) async => true,
      today: today,
    ));
    await tester.pumpAndSettle();
    expect(find.text('프로필을 입력하면 맞춤 추천을 받을 수 있어요'), findsOneWidget);
  });

  testWidgets('오류 시 상세 없이 안내와 재시도', (tester) async {
    final repo = FailingRepository();
    await tester.pumpWidget(GwittimApp(repository: repo, openUrl: (_) async => true, today: today));
    await tester.pumpAndSettle();

    expect(find.text('잠시 후 다시 시도해 주세요.'), findsOneWidget);
    expect(find.textContaining('RepositoryException'), findsNothing);
    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();
    expect(repo.calls, 2);
  });
}
