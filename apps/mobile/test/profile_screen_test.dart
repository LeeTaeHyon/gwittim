import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/main.dart';
import 'package:gwittim/ui/briefing_data.dart';
import 'package:gwittim/ui/profile_screen.dart';

void main() {
  Future<SampleNoticeRepository> openProfile(WidgetTester tester, {Future<void> Function()? onSignOut}) async {
    final repo = SampleNoticeRepository(personalized: false);
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
    await tester.tap(find.text('프로필'));
    await tester.pumpAndSettle();
    return repo;
  }

  Finder profileList() => find.descendant(of: find.byType(ProfileScreen), matching: find.byType(Scrollable)).first;

  Future<void> tapInList(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 200, scrollable: profileList());
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('순서와 안내: 학적 → 관심 분야 → 희망 직무 → 저장하기 → 화면', (tester) async {
    await openProfile(tester);
    expect(find.text('내 프로필'), findsOneWidget);
    expect(find.text('입력한 정보는 추천에만 써요'), findsOneWidget);
    expect(find.textContaining('성적·학번은 받지 않아요'), findsOneWidget);
    expect(find.text('명지전문대학'), findsOneWidget);

    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(top('학적'), lessThan(top('관심 분야')));
    await tester.scrollUntilVisible(find.text('화면'), 300, scrollable: profileList());
    await tester.pumpAndSettle();
    expect(top('희망 직무'), lessThan(top('저장하기')));
    expect(top('저장하기'), lessThan(top('화면')));
    expect(find.text('계정'), findsNothing); // 로그인 모드가 아니면 계정 칸이 없다
  });

  testWidgets('칩을 여러 개 고르면 고른 개수를 보이고, 다시 누르면 뺀다', (tester) async {
    final repo = await openProfile(tester);
    expect(find.text('0개 선택'), findsNWidgets(2));

    await tapInList(tester, find.text('소프트웨어 개발'));
    expect(find.text('1개 선택'), findsOneWidget);
    await tapInList(tester, find.text('AI·데이터'));
    expect(find.text('2개 선택'), findsOneWidget);
    await tapInList(tester, find.text('소프트웨어 개발'));
    expect(find.text('1개 선택'), findsOneWidget);

    await tapInList(tester, find.text('소프트웨어 개발자'));
    expect(find.text('1개 선택'), findsNWidgets(2));

    // 학년은 고른 칸을 다시 누르면 비운다
    await tapInList(tester, find.text('2학년'));
    await tapInList(tester, find.text('2학년'));
    await tapInList(tester, find.text('3학년'));
    await tapInList(tester, find.text('휴학'));

    // 학과는 아래 창에서 고른다
    await tapInList(tester, find.text('학과'));
    await tester.tap(find.text('컴퓨터공학과'));
    await tester.pumpAndSettle();
    expect(find.text('컴퓨터공학과'), findsOneWidget);

    await tapInList(tester, find.text('저장하기'));
    expect(find.text('프로필을 저장했어요.'), findsOneWidget);

    final p = (await repo.getProfile())!;
    expect(p.universityId, 'mjc');
    expect(p.majorId, 'mjc.computer_engineering');
    expect(p.grade, 3);
    expect(p.enrollmentStatus, 'on_leave');
    expect(p.interestIds, ['ai_data']);
    expect(p.targetRoleIds, ['software_developer']);
  });

  testWidgets('학과 선택 팝업: 가운데에 뜨고, 고른 학과에 체크, 이름으로 찾고 고르면 닫힌다', (tester) async {
    await openProfile(tester);
    await tapInList(tester, find.text('학과'));
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
    await tapInList(tester, find.text('학과'));
    await tester.tap(find.byTooltip('닫기'));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(find.text('컴퓨터보안공학과'), findsOneWidget);
  });

  testWidgets('학과를 "선택 안 함"으로 되돌리면 비워 저장한다', (tester) async {
    final repo = await openProfile(tester);
    await tapInList(tester, find.text('학과'));
    await tester.tap(find.text('컴퓨터공학과'));
    await tester.pumpAndSettle();
    await tapInList(tester, find.text('학과'));
    await tester.tap(find.text('선택 안 함').last);
    await tester.pumpAndSettle();
    await tapInList(tester, find.text('저장하기'));
    expect((await repo.getProfile())!.majorId, isNull);
    expect((await repo.getProfile())!.grade, isNull); // 고르지 않은 항목은 추정하지 않음
  });

  testWidgets('계정: 로그아웃은 동작하고, 탈퇴는 아직 화면만 있다', (tester) async {
    var signedOut = 0;
    await openProfile(tester, onSignOut: () async => signedOut++);
    await tapInList(tester, find.text('탈퇴하기'));
    expect(find.text('탈퇴는 아직 준비 중이에요.'), findsOneWidget);
    expect(find.text('탈퇴하면 프로필과 저장한 공고가 지워져요. 공고 자체는 그대로 남아요.'), findsOneWidget);
    expect(signedOut, 0);

    await tapInList(tester, find.text('로그아웃'));
    expect(signedOut, 1);
  });
}
