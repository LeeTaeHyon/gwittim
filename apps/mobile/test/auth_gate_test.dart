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

  testWidgets('예시 말풍선: 입력 중 표시 뒤에 하나씩 튀어나오고, 다 나온 뒤 흐려지며 되풀이한다', (tester) async {
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
    await tester.pump(const Duration(milliseconds: 800)); // 다음 바퀴 첫 입력 중
    expect(typing, findsOneWidget);
    expect(tester.hasRunningAnimations, isTrue);
  });

  testWidgets('예시는 7초마다 다음 세트로 넘어가 세 세트를 돌고, 버튼 자리는 그대로다', (tester) async {
    final auth = FakeAuth();
    await tester.pumpWidget(
      AuthGate(auth: auth, repositoryFor: (_) => SampleNoticeRepository(), openUrl: (_) async => true),
    );
    auth.start();
    await tester.pump();
    final buttonTop = tester.getTopLeft(find.byType(GoogleSignInButton)).dy;
    bool shown(String text) {
      final f = find.textContaining(text);
      if (find
          .ancestor(of: f, matching: find.byWidgetPredicate((w) => w is Visibility && !w.visible))
          .evaluate()
          .isNotEmpty) {
        return false;
      }
      return tester
          .widgetList<Opacity>(find.ancestor(of: f, matching: find.byType(Opacity)))
          .every((o) => o.opacity > 0.9);
    }

    await tester.pump(const Duration(milliseconds: 4000));
    expect(shown('장학생 선발 공고'), isTrue);
    expect(shown('학과·학년 조건이'), isFalse);

    await tester.pump(const Duration(milliseconds: 7000)); // 11초: 2세트
    expect(shown('학과·학년 조건이'), isTrue);
    expect(shown('평점 조건은 공지에서 확인해요'), isTrue);
    expect(shown('공모전 접수 · 오늘 마감'), isTrue);
    expect(shown('장학생 선발 공고'), isFalse);
    expect(tester.getTopLeft(find.byType(GoogleSignInButton)).dy, buttonTop);

    await tester.pump(const Duration(milliseconds: 7000)); // 18초: 3세트
    expect(shown('오늘 챙길 소식'), isTrue);
    expect(shown('희망 직무와 관련 있어요'), isTrue);
    expect(shown('해외 연수 · 정원 차면 마감돼요'), isTrue);
    expect(tester.getTopLeft(find.byType(GoogleSignInButton)).dy, buttonTop);

    await tester.pump(const Duration(milliseconds: 7000)); // 25초: 다시 1세트
    expect(shown('장학생 선발 공고'), isTrue);
    expect(shown('오늘 챙길 소식'), isFalse);
    expect(find.textContaining('알림'), findsNothing); // 어느 세트도 알림을 약속하지 않는다
  });

  testWidgets('애니메이션 줄이기 설정이면 예시 말풍선 셋이 그대로 보인다', (tester) async {
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
  });
}
