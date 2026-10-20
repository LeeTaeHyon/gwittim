import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/auth/auth_gate.dart';
import 'package:gwittim/auth/auth_service.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/ui/briefing_data.dart';

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
    expect(find.text('Google로 로그인'), findsOneWidget);

    await tester.tap(find.text('Google로 로그인'));
    await tester.pumpAndSettle();
    expect(find.text('홈'), findsOneWidget); // 하단 탭
    expect(await captured!(), 'fake-id-token');

    await tester.tap(find.text('프로필'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('로그아웃'));
    await tester.pumpAndSettle();
    expect(find.text('Google로 로그인'), findsOneWidget);
  });

  testWidgets('로그인 실패는 상세 없이 안내', (tester) async {
    final auth = FakeAuth(failWith: Exception('PlatformException(sign_in_failed, 10: DEVELOPER_ERROR)'));
    await tester.pumpWidget(
      AuthGate(auth: auth, repositoryFor: (_) => SampleNoticeRepository(), openUrl: (_) async => true),
    );
    auth.start();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Google로 로그인'));
    await tester.pumpAndSettle();
    expect(find.text('로그인하지 못했어요. 잠시 후 다시 시도해 주세요.'), findsOneWidget);
    expect(find.textContaining('DEVELOPER_ERROR'), findsNothing);
  });
}
