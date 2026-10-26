import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../main.dart';
import '../ui/briefing_data.dart';
import '../ui/common.dart';
import '../ui/logo.dart';
import '../ui/skeleton.dart';
import '../ui/theme.dart';
import 'auth_service.dart';
import 'google_sign_in_button.dart';

/// 로그인 전에는 로그인 화면, 로그인 후에는 서버 API를 쓰는 앱 본체.
class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.auth,
    required this.repositoryFor,
    required this.openUrl,
    this.briefingStore,
    this.themeController,
  });

  final AuthService auth;

  /// 로그인된 사용자의 토큰 공급자로 실제 Repository를 만든다.
  final NoticeRepository Function(Future<String?> Function() tokenProvider) repositoryFor;
  final OpenUrl openUrl;

  /// 테스트에서 바꿔 끼운다. 기본은 기기 저장소.
  final BriefingStore? briefingStore;

  /// 화면(테마) 설정. 로그인 화면도 같은 설정을 따른다.
  final ThemeController? themeController;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  ThemeController? _ownTheme;

  ThemeController get _theme => widget.themeController ?? (_ownTheme ??= ThemeController());

  @override
  void dispose() {
    _ownTheme?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: widget.auth.signedIn,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          // 로그인 화면과 같은 테마를 써야 테마 전환 애니메이션이 깨지지 않는다.
          return GwMaterialApp(
            themeController: _theme,
            home: const Scaffold(body: Center(child: GwLoadingLogo())),
          );
        }
        if (snapshot.data!) {
          return GwittimApp(
            repository: widget.repositoryFor(widget.auth.idToken),
            openUrl: widget.openUrl,
            onSignOut: widget.auth.signOut,
            briefingStore: widget.briefingStore,
            themeController: _theme,
          );
        }
        return GwMaterialApp(themeController: _theme, home: SignInScreen(auth: widget.auth));
      },
    );
  }
}

/// 로그인 화면 (D-010). 소개 문구에서 알림을 약속하지 않는다 (푸시 알림은 P0 제외).
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
      // false: 사용자가 창을 닫았거나, 기기에 Google 계정이 없어 창이 뜨지 않은 경우(둘을 구분할 수 없음)
      if (!await widget.auth.signInWithGoogle()) {
        messenger.showSnackBar(const SnackBar(content: Text('로그인을 마치지 못했어요. 기기에 Google 계정이 있는지 확인해 주세요.')));
      }
    } catch (_) {
      // 상세 오류는 화면에 보여주지 않는다 (SPEC §10)
      messenger.showSnackBar(const SnackBar(content: Text('로그인하지 못했어요. 잠시 후 다시 시도해 주세요.')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return AnnotatedRegion(
      value: statusBarStyle(Brightness.dark), // 로그인 바탕은 라이트·다크 모두 어둡다
      child: Scaffold(
        backgroundColor: c.loginBg,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight - 28),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 60),
                      const Align(alignment: Alignment.centerLeft, child: GwLogo(height: 56)),
                      const SizedBox(height: 28),
                      Semantics(
                        header: true,
                        child: Text(
                          '몰랐던 기회를\n먼저 귀띔해 드려요',
                          style: TextStyle(
                            fontSize: 30,
                            height: 1.38,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.9,
                            color: c.loginInk,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        // 추천은 관련도 순이라 '마감 순'이라고 쓰지 않는다.
                        '학교 공지 중 나에게 맞는 공고를 골라 지원 조건·마감과 함께 정리해 드려요.',
                        style: TextStyle(fontSize: 16, height: 1.6, color: c.loginSub),
                      ),
                      const SizedBox(height: 36),
                      // 앱이 알려 주는 소식의 예시 (D-010)
                      _ExampleBubble(kicker: '마감 임박', kickerColor: c.urgent, text: '장학생 선발 공고 · D-6'),
                      const SizedBox(height: 10),
                      Padding(
                        padding: const EdgeInsets.only(left: 32),
                        child: _ExampleBubble(
                          kicker: '맞춤 공고',
                          kickerColor: c.accent,
                          text: '관심 분야와 관련된 공고 ',
                          marked: '3개',
                        ),
                      ),
                      const SizedBox(height: 10),
                      Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: _ExampleBubble(
                          kicker: '저장한 공고',
                          kickerColor: c.accent,
                          text: '발표회 마감이 3일 늦춰졌어요',
                        ),
                      ),
                      const Spacer(),
                      const SizedBox(height: 36),
                      GoogleSignInButton(label: 'Google 계정으로 시작하기', onPressed: _busy ? null : _signIn),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.lock_outline_rounded, size: 15, color: c.loginSub),
                          const SizedBox(width: 6),
                          Text('성적·학번은 묻지 않아요', style: TextStyle(fontSize: 13, color: c.loginSub)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _TermsLine(color: c.loginSub, linkColor: c.loginInk),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExampleBubble extends StatelessWidget {
  const _ExampleBubble({required this.kicker, required this.kickerColor, required this.text, this.marked});

  final String kicker;
  final Color kickerColor;
  final String text;

  /// 라임 바탕으로 강조할 끝 낱말
  final String? marked;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          color: c.loginCard,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
            bottomRight: Radius.circular(20),
            bottomLeft: Radius.circular(6),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(kicker, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: kickerColor)),
            const SizedBox(height: 3),
            // 화면 높이 계산(IntrinsicHeight) 안에 있어서 형광펜 위젯 대신 글자 바탕색을 쓴다.
            Text.rich(
              TextSpan(
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.ink),
                children: [
                  TextSpan(text: text),
                  if (marked != null)
                    TextSpan(
                      text: ' $marked ',
                      style: TextStyle(backgroundColor: c.lime, color: c.limeInk),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 이용약관·개인정보 처리방침 동의 문구. 문서가 아직 없어 링크 자리만 둔다 (D-010 한계).
class _TermsLine extends StatelessWidget {
  const _TermsLine({required this.color, required this.linkColor});

  final Color color;
  final Color linkColor;

  @override
  Widget build(BuildContext context) {
    final link = TextStyle(color: linkColor, decoration: TextDecoration.underline, decorationColor: linkColor);
    return Text.rich(
      TextSpan(
        style: TextStyle(fontSize: 12.5, height: 1.6, color: color),
        children: [
          const TextSpan(text: '시작하면 '),
          TextSpan(text: '이용약관', style: link),
          const TextSpan(text: '과 '),
          TextSpan(text: '개인정보 처리방침', style: link),
          const TextSpan(text: '에 동의하게 돼요'),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}
