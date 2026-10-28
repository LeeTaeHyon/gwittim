import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/auth/auth_gate.dart';
import 'package:gwittim/auth/auth_service.dart';
import 'package:gwittim/auth/google_sign_in_button.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/ui/briefing_data.dart';
import 'package:gwittim/ui/profile_screen.dart';
import 'package:gwittim/ui/theme.dart';

class FakeAuth implements AuthService {
  FakeAuth({this.failWith});

  final Object? failWith;
  final _state = StreamController<bool>.broadcast();
  bool _signedIn = false;
  int signInCalls = 0;

  void start() => _state.add(false);

  @override
  Stream<bool> get signedIn => _state.stream;

  @override
  Future<String?> idToken() async => _signedIn ? 'fake-id-token' : null;

  @override
  Future<bool> signInWithGoogle() async {
    signInCalls++;
    if (failWith != null) throw failWith!;
    _signedIn = true;
    _state.add(true);
    return true;
  }

  @override
  Future<void> signOut() async {
    _signedIn = false;
    _state.add(false);
  }
}

/// 로그인 화면의 예시 장면은 계속 되풀이되어 pumpAndSettle이 끝나지 않는다. 화면 전환이 끝날 만큼만 진행한다.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  Future<SampleNoticeRepository> loaded(WidgetTester tester) async {
    final repo = SampleNoticeRepository();
    await tester.runAsync(repo.preload);
    return repo;
  }

  testWidgets('로그인 전에는 로그인 화면, 로그인하면 앱 본체와 토큰 공급자', (tester) async {
    final auth = FakeAuth();
    final repo = await loaded(tester);
    Future<String?> Function()? captured;
    await tester.pumpWidget(
      AuthGate(
        auth: auth,
        repositoryFor: (tp) {
          captured = tp;
          return repo;
        },
        openUrl: (_) async => true,
        briefingStore: MemoryBriefingStore(alwaysShown: true),
      ),
    );
    auth.start();
    await settle(tester);
    expect(find.text('Google 계정으로 시작하기'), findsOneWidget);

    await tester.tap(find.text('Google 계정으로 시작하기'));
    await settle(tester);
    expect(find.text('오늘'), findsOneWidget); // 하단 탭
    expect(await captured!(), 'fake-id-token');

    // 로그아웃은 내 정보 설정의 계정 칸에 있다 (D-010)
    await tester.tap(find.byTooltip('내 정보'));
    await settle(tester);
    await tester.scrollUntilVisible(
      find.text('로그아웃'),
      300,
      scrollable: find.descendant(of: find.byType(ProfileScreen), matching: find.byType(Scrollable)).first,
    );
    await settle(tester);
    expect(find.text('Google 계정으로 로그인했어요'), findsOneWidget);
    await tester.tap(find.text('로그아웃'));
    await settle(tester);
    expect(find.text('Google 계정으로 시작하기'), findsOneWidget);
  });

  testWidgets('로그인 화면: 공식 Google 버튼, 성적·학번 안내, 약관 문구, 알림 약속 없음', (tester) async {
    final auth = FakeAuth();
    await tester.pumpWidget(
      AuthGate(auth: auth, repositoryFor: (_) => SampleNoticeRepository(), openUrl: (_) async => true),
    );
    auth.start();
    await settle(tester);

    expect(find.bySemanticsLabel('귀띔'), findsOneWidget); // 직접 그린 로고 (D-011)
    expect(find.text('몰랐던 기회를\n먼저 귀띔해 드려요'), findsOneWidget);
    expect(find.byType(GoogleSignInButton), findsOneWidget);
    expect(find.descendant(of: find.byType(GoogleSignInButton), matching: find.byType(GoogleLogo)), findsOneWidget);
    expect(find.text('성적·학번은 묻지 않아요'), findsOneWidget);
    expect(find.text('시작하면 이용약관과 개인정보 처리방침에 동의하게 돼요'), findsOneWidget);
    expect(find.textContaining('알림'), findsNothing);
    expect(find.textContaining('알려'), findsNothing);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, GwColors.light.loginBg);
  });

  testWidgets('다크 설정이면 로그인 바탕도 다크', (tester) async {
    final auth = FakeAuth();
    await tester.pumpWidget(
      AuthGate(
        auth: auth,
        repositoryFor: (_) => SampleNoticeRepository(),
        openUrl: (_) async => true,
        themeController: ThemeController(initial: ThemeMode.dark),
      ),
    );
    auth.start();
    await settle(tester);
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor, const Color(0xFF0F1222));
  });

  testWidgets('로그인 실패는 상세 없이 안내', (tester) async {
    final auth = FakeAuth(failWith: Exception('PlatformException(sign_in_failed, 10: DEVELOPER_ERROR)'));
    await tester.pumpWidget(
      AuthGate(auth: auth, repositoryFor: (_) => SampleNoticeRepository(), openUrl: (_) async => true),
    );
    auth.start();
    await settle(tester);
    await tester.tap(find.text('Google 계정으로 시작하기'));
    await settle(tester);
    expect(find.text('로그인하지 못했어요. 잠시 후 다시 시도해 주세요.'), findsOneWidget);
    expect(find.textContaining('DEVELOPER_ERROR'), findsNothing);
  });

  testWidgets('장면 1 말풍선: 입력 중 표시 뒤에 하나씩 튀어나오고, 다 나온 뒤 흐려진다', (tester) async {
    final auth = FakeAuth();
    await tester.pumpWidget(
      AuthGate(auth: auth, repositoryFor: (_) => SampleNoticeRepository(), openUrl: (_) async => true),
    );
    auth.start();
    await tester.pump();
    final typing = find.byKey(const ValueKey('typing'));
    double opacityOf(String text) => tester
        .widgetList<Opacity>(find.ancestor(of: find.textContaining(text), matching: find.byType(Opacity)))
        .fold(1.0, (o, w) => o * w.opacity);
    final buttonTop = tester.getTopLeft(find.byType(GoogleSignInButton)).dy;

    await tester.pump(const Duration(milliseconds: 500)); // 첫 말풍선 입력 중
    expect(typing, findsOneWidget);
    expect(opacityOf('장학생 선발 공고'), 0);
    expect(find.text('장학생 선발 공고 · D-6'), findsOneWidget); // 안 보여도 화면 읽기에는 남는다

    await tester.pump(const Duration(milliseconds: 1000)); // 1.5초: 첫 말풍선 도착, 둘째 입력 중
    expect(opacityOf('장학생 선발 공고'), 1);
    expect(opacityOf('관심 분야와 관련된 공고'), 0);
    expect(typing, findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2500)); // 4초: 셋 다 보인다
    expect(typing, findsNothing);
    for (final t in ['장학생 선발 공고', '관심 분야와 관련된 공고', '발표회 마감이']) {
      expect(opacityOf(t), 1);
    }
    expect(tester.getTopLeft(find.byType(GoogleSignInButton)).dy, buttonTop); // 아래 버튼은 움직이지 않는다

    await tester.pump(const Duration(milliseconds: 2700)); // 6.7초: 흐려짐
    expect(opacityOf('장학생 선발 공고'), lessThan(0.1));
    await tester.pump(const Duration(milliseconds: 800)); // 다음 장면
    expect(typing, findsNothing);
    expect(tester.hasRunningAnimations, isTrue);
  });

  /// 안 보이는 장면(자리만 차지)에 있거나 흐린 글자는 보이지 않는 것으로 친다.
  bool shown(WidgetTester tester, String text) {
    final f = find.textContaining(text);
    final hidden = find.ancestor(of: f, matching: find.byWidgetPredicate((w) => w is Visibility && !w.visible));
    if (hidden.evaluate().isNotEmpty) return false;
    return tester
        .widgetList<Opacity>(find.ancestor(of: f, matching: find.byType(Opacity)))
        .every((o) => o.opacity > 0.9);
  }

  Future<void> pumpSignIn(WidgetTester tester) async {
    final auth = FakeAuth();
    await tester.pumpWidget(
      AuthGate(auth: auth, repositoryFor: (_) => SampleNoticeRepository(), openUrl: (_) async => true),
    );
    auth.start();
    await tester.pump();
  }

  testWidgets('소개 장면: 말풍선 → 체크리스트 → 관심 분야로 바뀌는 추천 순서, 버튼 자리는 그대로', (tester) async {
    await pumpSignIn(tester);
    final buttonTop = tester.getTopLeft(find.byType(GoogleSignInButton)).dy;
    Finder box(int i, String state) => find.byKey(ValueKey('box-$i-$state'));

    await tester.pump(const Duration(milliseconds: 4000));
    expect(shown(tester, '장학생 선발 공고'), isTrue);
    expect(shown(tester, '지원 전 체크리스트'), isFalse);

    // 장면 2: 카드가 아래에서 올라오고, 조건 줄은 빈 칸으로 먼저 보인다
    await tester.pump(const Duration(milliseconds: 3400)); // 7.4초
    final cardTop = tester.getTopLeft(find.text('지원 전 체크리스트')).dy;
    await tester.pump(const Duration(milliseconds: 400)); // 7.8초
    expect(tester.getTopLeft(find.text('지원 전 체크리스트')).dy, lessThan(cardTop)); // 올라오는 중
    expect(shown(tester, '공지에서 직접 확인'), isTrue);
    for (var i = 0; i < 3; i++) {
      expect(box(i, 'off'), findsOneWidget);
    }
    expect(
      find.byType(Transform).evaluate().every((e) {
        final t = (e.widget as Transform).transform;
        return t.getMaxScaleOnAxis() <= 1.0001; // 카드가 커지며 나오지 않는다
      }),
      isTrue,
    );

    await tester.pump(const Duration(milliseconds: 900)); // 8.7초: 첫 줄만 체크
    expect(box(0, 'on'), findsOneWidget);
    expect(box(1, 'off'), findsOneWidget);
    expect(box(2, 'off'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2300)); // 11초: 모두 체크
    for (var i = 0; i < 3; i++) {
      expect(box(i, 'on'), findsOneWidget);
    }
    expect(shown(tester, '2개는 맞아요'), isTrue);
    expect(shown(tester, '장학생 선발 공고'), isFalse);
    expect(tester.getTopLeft(find.byType(GoogleSignInButton)).dy, buttonTop);

    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    await tester.pump(const Duration(milliseconds: 3800)); // 14.8초: 장면 3 카드가 다 올라옴, 아직 원래 순서
    expect(shown(tester, '추천 순서가 바뀌어요'), isTrue);
    expect(y('AI 해커톤 참가자 모집'), greaterThan(y('교내 디자인 공모전')));
    await tester.pump(const Duration(milliseconds: 2700)); // 17.5초: 관심 분야 칩을 고른 뒤
    expect(y('AI 해커톤 참가자 모집'), lessThan(y('교내 디자인 공모전')));
    expect(shown(tester, '관심 분야 '), isTrue);
    expect(tester.getTopLeft(find.byType(GoogleSignInButton)).dy, buttonTop);

    await tester.pump(const Duration(milliseconds: 4000)); // 21.5초: 다시 장면 1
    expect(shown(tester, '추천 순서가 바뀌어요'), isFalse);
    expect(find.byKey(const ValueKey('typing')), findsOneWidget);
    expect(find.byKey(const ValueKey('progress-0')), findsNothing); // 진행 표시는 없다
    expect(find.textContaining('알림'), findsNothing); // 어느 장면도 알림을 약속하지 않는다
  });

  testWidgets('소개 장면을 누르면 다음 장면으로 넘어간다', (tester) async {
    await pumpSignIn(tester);
    await tester.pump(const Duration(milliseconds: 2000));
    await tester.tap(find.text('장학생 선발 공고 · D-6'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    expect(shown(tester, '지원 전 체크리스트'), isTrue);
    expect(tester.hasRunningAnimations, isTrue); // 넘어간 뒤에도 계속 돈다
  });

  testWidgets('애니메이션 줄이기 설정이면 장면이 멈춰 있고, 누를 때만 넘어간다', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final auth = FakeAuth();
    await tester.pumpWidget(
      AuthGate(auth: auth, repositoryFor: (_) => SampleNoticeRepository(), openUrl: (_) async => true),
    );
    auth.start();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('typing')), findsNothing);
    expect(find.text('발표회 마감이 3일 늦춰졌어요'), findsOneWidget);
    final opacities = tester.widgetList<Opacity>(
      find.ancestor(of: find.text('발표회 마감이 3일 늦춰졌어요'), matching: find.byType(Opacity)),
    );
    expect(opacities.every((o) => o.opacity == 1), isTrue);

    await tester.tap(find.text('장학생 선발 공고 · D-6'));
    await tester.pump();
    expect(shown(tester, '공지에서 직접 확인'), isTrue); // 움직이지 않고 다 보인 채로 넘어간다
    expect(tester.hasRunningAnimations, isFalse);
  });

  group('로그인 화면 크기 맞춤', () {
    // (폭, 높이, 글자 배율, 스크롤 없이 들어가야 하는지). 위아래 시스템 막대 24씩.
    for (final (w, h, scale, fits) in [
      (360.0, 640.0, 1.0, false),
      (360.0, 760.0, 1.0, true),
      (360.0, 780.0, 1.0, true),
      (412.0, 915.0, 1.0, true),
      (412.0, 915.0, 1.3, true),
      (360.0, 780.0, 1.3, false),
      (412.0, 915.0, 1.5, false),
    ]) {
      testWidgets('$w×$h 글자 $scale배: 버튼과 약관은 늘 보이고${fits ? ', 스크롤 없음' : ''}', (tester) async {
        tester.view.physicalSize = Size(w * 3, h * 3);
        tester.view.devicePixelRatio = 3;
        tester.view.padding = const FakeViewPadding(top: 72, bottom: 72);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpSignIn(tester);
        await settle(tester);

        final bottom = h - 24;
        expect(tester.getRect(find.byType(GoogleSignInButton)).bottom, lessThanOrEqualTo(bottom));
        expect(tester.getRect(find.textContaining('동의하게 돼요')).bottom, lessThanOrEqualTo(bottom));
        final over = tester.state<ScrollableState>(find.byType(Scrollable).first).position.maxScrollExtent;
        if (fits) expect(over, 0);
        expect(tester.takeException(), isNull);

        // 줄여 맞춘 뒤에도 소개 장면은 계속 돈다
        await tester.pump(const Duration(milliseconds: 3000));
        expect(shown(tester, '발표회 마감이'), isTrue);
        expect(tester.hasRunningAnimations, isTrue);
      });
    }
  });
}
