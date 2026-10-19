import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../main.dart';
import '../ui/common.dart';
import 'auth_service.dart';

/// 로그인 전에는 로그인 화면, 로그인 후에는 서버 API를 쓰는 앱 본체.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key, required this.auth, required this.repositoryFor, required this.openUrl});

  final AuthService auth;

  /// 로그인된 사용자의 토큰 공급자로 실제 Repository를 만든다.
  final NoticeRepository Function(Future<String?> Function() tokenProvider) repositoryFor;
  final OpenUrl openUrl;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: auth.signedIn,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const MaterialApp(
            home: Scaffold(body: Center(child: CircularProgressIndicator())),
          );
        }
        if (snapshot.data!) {
          return GwittimApp(repository: repositoryFor(auth.idToken), openUrl: openUrl, onSignOut: auth.signOut);
        }
        return MaterialApp(
          title: '귀띔',
          theme: gwittimTheme(Brightness.light),
          darkTheme: gwittimTheme(Brightness.dark),
          home: SignInScreen(auth: auth),
        );
      },
    );
  }
}

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.auth});

  final AuthService auth;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  bool _busy = false;

  Future<void> _signIn() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.auth.signInWithGoogle();
    } catch (_) {
      // 상세 오류는 화면에 보여주지 않는다 (SPEC §10)
      messenger.showSnackBar(const SnackBar(content: Text('로그인하지 못했어요. 잠시 후 다시 시도해 주세요.')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('귀띔', style: text.displaySmall, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Text('놓치기 쉬운 교내외 기회를 지원 조건과 함께 알려 드려요.', style: text.bodyMedium, textAlign: TextAlign.center),
              const SizedBox(height: 40),
              FilledButton.icon(
                onPressed: _busy ? null : _signIn,
                icon: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.login),
                label: const Text('Google로 로그인'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
