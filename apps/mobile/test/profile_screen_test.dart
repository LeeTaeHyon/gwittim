import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/main.dart';
import 'package:gwittim/ui/briefing_data.dart';
import 'package:gwittim/ui/profile_screen.dart';

/// 프로필 저장만 실패한다.
class SaveFails extends SampleNoticeRepository {
  SaveFails() : super(personalized: false);

  @override
  Future<void> updateProfile(UserProfile profile) async =>
      throw const RepositoryException(RepositoryErrorKind.unavailable);
}

void main() {
  Future<T> openProfile<T extends SampleNoticeRepository>(
    WidgetTester tester, {
    T? repository,
    Future<void> Function()? onSignOut,
  }) async {
    final repo = repository ?? SampleNoticeRepository(personalized: false) as T;
    await tester.runAsync(repo.preload);
    await tester.pumpWidget(
      GwittimApp(
        repository: repo,
        openUrl: (_) async => true,
        today: DateTime(2026, 10, 17),
        briefingStore: MemoryBriefingStore(alwaysShown: true),
        onSignOut: onSignOut,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('내 정보')); // 홈 머리 오른쪽
    await tester.pumpAndSettle();
    return repo;
  }

  Finder profileList() => find.descendant(of: find.byType(ProfileScreen), matching: find.byType(Scrollable)).first;
  Finder editList() => find.descendant(of: find.byType(ProfileEditScreen), matching: find.byType(Scrollable)).first;

  Future<void> tapIn(WidgetTester tester, Finder list, Finder finder) async {
    await tester.scrollUntilVisible(finder, 200, scrollable: list);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> next(WidgetTester tester) async {
    await tester.tap(find.text('다음'));
    await tester.pumpAndSettle();
  }

  testWidgets('요약 카드 → 안내 → 설정. 비어 있으면 아직 입력하지 않았다고 보인다', (tester) async {
    await openProfile(tester);
    expect(find.text('내 정보'), findsWidgets);
    expect(find.text('아직 입력하지 않았어요'), findsOneWidget);
    expect(find.text('입력하기'), findsOneWidget);
    expect(find.text('입력한 정보는 추천에만 써요'), findsOneWidget);
    expect(find.textContaining('성적·학번은 받지 않아요'), findsOneWidget);

    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(top('아직 입력하지 않았어요'), lessThan(top('입력한 정보는 추천에만 써요')));
    await tester.scrollUntilVisible(find.text('라이트'), 200, scrollable: profileList());
    expect(top('설정'), lessThan(top('화면')));
    expect(find.text('계정'), findsNothing); // 로그인 모드가 아니면 계정 칸이 없다
  });

  testWidgets('세 단계로 고치고 마지막 단계에서 저장하면 요약 카드가 바뀐다', (tester) async {
    final repo = await openProfile(tester);
    await tester.tap(find.text('입력하기'));
    await tester.pumpAndSettle();

    // 1단계 학적
    expect(find.bySemanticsLabel('1/3단계'), findsOneWidget);
    expect(find.text('명지전문대학'), findsOneWidget); // P0 학교가 기본
    expect(find.text('저장하기'), findsNothing);
    await tapIn(tester, editList(), find.text('2학년'));
    await tapIn(tester, editList(), find.text('2학년')); // 고른 칸을 다시 누르면 비운다
    await tapIn(tester, editList(), find.text('3학년'));
    await tapIn(tester, editList(), find.text('휴학'));
    await tapIn(tester, editList(), find.text('학과'));
    await tester.tap(find.text('컴퓨터공학과'));
    await tester.pumpAndSettle();
    expect(find.text('컴퓨터공학과'), findsOneWidget);
    await next(tester);

    // 2단계 관심 분야: 칩을 여러 개 고르면 개수를 보이고, 다시 누르면 뺀다
    expect(find.bySemanticsLabel('2/3단계'), findsOneWidget);
    expect(find.text('0개 선택'), findsOneWidget);
    await tapIn(tester, editList(), find.text('소프트웨어 개발'));
    await tapIn(tester, editList(), find.text('AI·데이터'));
    expect(find.text('2개 선택'), findsOneWidget);
    await tapIn(tester, editList(), find.text('소프트웨어 개발'));
    expect(find.text('1개 선택'), findsOneWidget);

    // 뒤로 가면 앞 단계로, 고른 값은 남아 있다
    await tester.tap(find.byTooltip('뒤로'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('1/3단계'), findsOneWidget);
    expect(find.text('컴퓨터공학과'), findsOneWidget);
    await next(tester);
    expect(find.text('1개 선택'), findsOneWidget);
    await next(tester);

    // 3단계 희망 직무 → 저장하기
    expect(find.bySemanticsLabel('3/3단계'), findsOneWidget);
    await tapIn(tester, editList(), find.text('소프트웨어 개발자'));
    await tester.tap(find.text('저장하기'));
    await tester.pumpAndSettle();
    expect(find.text('프로필을 저장했어요.'), findsOneWidget);
    expect(find.byType(ProfileEditScreen), findsNothing);

    final p = (await repo.getProfile())!;
    expect(p.universityId, 'mjc');
    expect(p.majorId, 'mjc.computer_engineering');
    expect(p.grade, 3);
    expect(p.enrollmentStatus, 'on_leave');
    expect(p.interestIds, ['ai_data']);
    expect(p.targetRoleIds, ['software_developer']);

    expect(find.text('명지전문대학 컴퓨터공학과 3학년 · 휴학'), findsOneWidget);
    expect(find.text('AI·데이터'), findsOneWidget);
    expect(find.text('소프트웨어 개발자'), findsOneWidget);
    expect(find.text('고치기'), findsOneWidget);
  });

  testWidgets('저장에 실패하면 알리고 입력은 남긴다', (tester) async {
    await openProfile(tester, repository: SaveFails());
    await tester.tap(find.text('입력하기'));
    await tester.pumpAndSettle();
    await next(tester);
    await tapIn(tester, editList(), find.text('AI·데이터'));
    await next(tester);
    await tester.tap(find.text('저장하기'));
    await tester.pumpAndSettle();
    expect(find.text('잠시 후 다시 시도해 주세요.'), findsOneWidget);
    expect(find.byType(ProfileEditScreen), findsOneWidget);
    await tester.tap(find.byTooltip('뒤로'));
    await tester.pumpAndSettle();
    expect(find.text('1개 선택'), findsOneWidget);
  });

  testWidgets('학과 선택 팝업: 가운데에 뜨고, 고른 학과에 체크, 이름으로 찾고 고르면 닫힌다', (tester) async {
    await openProfile(tester);
    await tester.tap(find.text('입력하기'));
    await tester.pumpAndSettle();
    await tapIn(tester, editList(), find.text('학과'));
    final sheet = find.byType(Dialog);
    Finder inSheet(Finder f) => find.descendant(of: sheet, matching: f);
    expect(inSheet(find.text('학과 선택')), findsOneWidget);
    final screen = tester.getRect(find.byType(MaterialApp));
    final card = tester.getRect(inSheet(find.byType(Material)).first);
    expect(card.center.dx, moreOrLessEquals(screen.center.dx));
    expect(card.bottom, lessThan(screen.bottom)); // 바닥에 붙지 않는다
    expect(inSheet(find.byIcon(Icons.check_rounded)), findsOneWidget); // '선택 안 함'에 체크
    expect(inSheet(find.text('선택 안 함')), findsOneWidget);

    await tester.enterText(inSheet(find.byType(TextField)), '보안');
    await tester.pumpAndSettle();
    expect(inSheet(find.text('컴퓨터보안공학과')), findsOneWidget);
    expect(inSheet(find.text('컴퓨터공학과')), findsNothing);
    expect(inSheet(find.text('선택 안 함')), findsNothing);

    await tester.enterText(inSheet(find.byType(TextField)), '없는학과');
    await tester.pumpAndSettle();
    expect(inSheet(find.text('찾는 학과가 없어요')), findsOneWidget);

    await tester.enterText(inSheet(find.byType(TextField)), '보안');
    await tester.pumpAndSettle();
    await tester.tap(inSheet(find.text('컴퓨터보안공학과')));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(find.text('컴퓨터보안공학과'), findsOneWidget); // 학과 줄에 보인다

    // 닫기 버튼은 고르지 않고 닫는다
    await tapIn(tester, editList(), find.text('학과'));
    await tester.tap(find.descendant(of: sheet, matching: find.byTooltip('닫기')));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(find.text('컴퓨터보안공학과'), findsOneWidget);
  });

  testWidgets('학과를 "선택 안 함"으로 되돌리면 비워 저장한다', (tester) async {
    final repo = await openProfile(tester);
    await tester.tap(find.text('입력하기'));
    await tester.pumpAndSettle();
    await tapIn(tester, editList(), find.text('학과'));
    await tester.tap(find.text('컴퓨터공학과'));
    await tester.pumpAndSettle();
    await tapIn(tester, editList(), find.text('학과'));
    await tester.tap(find.text('선택 안 함').last);
    await tester.pumpAndSettle();
    await next(tester);
    await next(tester);
    await tester.tap(find.text('저장하기'));
    await tester.pumpAndSettle();
    expect((await repo.getProfile())!.majorId, isNull);
    expect((await repo.getProfile())!.grade, isNull); // 고르지 않은 항목은 추정하지 않음
    expect((await repo.getProfile())!.interestIds, isEmpty);
  });

  testWidgets('고른 칸 바탕은 양옆으로 미끄러지고, 비우면 그 자리에서 흐려진다', (tester) async {
    await openProfile(tester);
    final thumb = find.byKey(const ValueKey('segment-thumb'));
    await tester.scrollUntilVisible(find.text('라이트'), 200, scrollable: profileList());
    await tester.pumpAndSettle();
    double x() => tester.getCenter(thumb).dx;
    double center(String label) => tester.getCenter(find.text(label)).dx;
    expect(x(), moreOrLessEquals(center('시스템 설정'), epsilon: 1));

    await tester.tap(find.text('다크'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(x(), greaterThan(center('시스템 설정') + 1)); // 가는 중
    expect(x(), lessThan(center('다크') - 1));
    await tester.pumpAndSettle();
    expect(x(), moreOrLessEquals(center('다크'), epsilon: 1));

    // 고치기의 학년: 고른 칸을 다시 누르면 바탕이 그 자리에서 흐려진다
    await tester.scrollUntilVisible(find.text('입력하기'), -200, scrollable: profileList());
    await tester.tap(find.text('입력하기'));
    await tester.pumpAndSettle();
    final grade = find.descendant(
      of: find.ancestor(of: find.text('2학년'), matching: find.byType(LayoutBuilder)).first,
      matching: thumb,
    );
    double opacity() =>
        tester.widget<AnimatedOpacity>(find.descendant(of: grade, matching: find.byType(AnimatedOpacity))).opacity;
    expect(opacity(), 0); // 아직 고르지 않음
    await tapIn(tester, editList(), find.text('3학년'));
    expect(opacity(), 1);
    expect(tester.getCenter(grade).dx, moreOrLessEquals(center('3학년'), epsilon: 1));
    await tapIn(tester, editList(), find.text('3학년'));
    expect(opacity(), 0);
    expect(tester.getCenter(grade).dx, moreOrLessEquals(center('3학년'), epsilon: 1));
  });

  testWidgets('애니메이션 줄이기 설정이면 고른 칸 바탕이 바로 옮겨 간다', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await openProfile(tester);
    await tester.scrollUntilVisible(find.text('라이트'), 200, scrollable: profileList());
    await tester.tap(find.text('다크'));
    await tester.pump();
    await tester.pump();
    expect(
      tester.getCenter(find.byKey(const ValueKey('segment-thumb'))).dx,
      moreOrLessEquals(tester.getCenter(find.text('다크')).dx, epsilon: 1),
    );
  });

  testWidgets('계정: 로그아웃은 동작하고, 탈퇴는 아직 화면만 있다', (tester) async {
    var signedOut = 0;
    await openProfile(tester, onSignOut: () async => signedOut++);
    await tapIn(tester, profileList(), find.text('탈퇴하기'));
    expect(find.text('탈퇴는 아직 준비 중이에요.'), findsOneWidget);
    expect(find.text('탈퇴하면 프로필과 저장한 공고가 지워져요. 공고 자체는 그대로 남아요.'), findsOneWidget);
    expect(signedOut, 0);

    await tapIn(tester, profileList(), find.text('로그아웃'));
    expect(signedOut, 1);
  });
}
