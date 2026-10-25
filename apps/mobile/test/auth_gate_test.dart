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
    await tester.pumpAndSettle();
    expect(find.text('Google 계정으로 시작하기'), findsOneWidget);

    await tester.tap(find.text('Google 계정으로 시작하기'));
    await tester.pumpAndSettle();
    expect(find.text('홈'), findsOneWidget); // 하단 탭
    expect(await captured!(), 'fake-id-token');

    // 로그아웃은 프로필 맨 아래 계정 칸에 있다 (D-010)
    await tester.tap(find.text('프로필'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('로그아웃'),
      300,
      scrollable: find.descendant(of: find.byType(ProfileScreen), matching: find.byType(Scrollable)).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Google 계정으로 로그인했어요'), findsOneWidget);
    await tester.tap(find.text('로그아웃'));
    await tester.pumpAndSettle();
    expect(find.text('Google 계정으로 시작하기'), findsOneWidget);
  });

  testWidgets('로그인 화면: 공식 Google 버튼, 성적·학번 안내, 약관 문구, 알림 약속 없음', (tester) async {
    final auth = FakeAuth();
    await tester.pumpWidget(
      AuthGate(auth: auth, repositoryFor: (_) => SampleNoticeRepository(), openUrl: (_) async => true),
    );
    auth.start();
    await tester.pumpAndSettle();

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
    await tester.pumpAndSettle();
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor, const Color(0xFF0F1222));
  });

  testWidgets('로그인 실패는 상세 없이 안내', (tester) async {
    final auth = FakeAuth(failWith: Exception('PlatformException(sign_in_failed, 10: DEVELOPER_ERROR)'));
    await tester.pumpWidget(
      AuthGate(auth: auth, repositoryFor: (_) => SampleNoticeRepository(), openUrl: (_) async => true),
    );
    auth.start();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Google 계정으로 시작하기'));
    await tester.pumpAndSettle();
    expect(find.text('로그인하지 못했어요. 잠시 후 다시 시도해 주세요.'), findsOneWidget);
    expect(find.textContaining('DEVELOPER_ERROR'), findsNothing);
  });
}
