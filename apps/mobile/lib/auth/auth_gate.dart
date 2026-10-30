import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../main.dart';
import '../ui/briefing_data.dart';
import '../ui/common.dart';
import '../ui/format.dart';
import '../ui/logo.dart';
import '../ui/skeleton.dart';
import '../ui/theme.dart';
import 'auth_service.dart';
import 'google_sign_in_button.dart';
import 'sign_in_demo.dart';

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
        return GwMaterialApp(
          themeController: _theme,
          home: SignInScreen(auth: widget.auth),
        );
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

  final _scroll = ScrollController();
  final _demoKey = GlobalKey();

  /// 화면에 다 들어가지 않을 때 줄이는 단계: 0 그대로, 1 여백을 줄임, 2 소개 장면도 줄임(최대 0.75배).
  /// 그래도 넘치는 아주 작은 화면·큰 글자에서만 스크롤한다.
  int _fit = 0;
  double _demoScale = 1;
  double _demoHeight = 0;

  /// 화면 크기·글자 크기가 바뀌면 처음부터 다시 맞춘다.
  (Size, double)? _fittedFor;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _fitLater() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || _fit == 2) return;
      final over = _scroll.position.maxScrollExtent;
      if (over <= 0.5) return;
      if (_fit == 0) {
        setState(() => _fit = 1);
        _fitLater();
        return;
      }
      final natural = _demoKey.currentContext?.size?.height ?? 0;
      if (natural <= 0) return;
      setState(() {
        _fit = 2;
        _demoHeight = natural;
        _demoScale = ((natural - over) / natural).clamp(0.75, 1.0);
      });
    });
  }

  Future<void> _signIn() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // false: 사용자가 창을 닫았거나, 기기에 Google 계정이 없어 창이 뜨지 않은 경우(둘을 구분할 수 없음)
      if (!await widget.auth.signInWithGoogle()) {
        messenger.showSnackBar(SnackBar(content: Text(keepAll('로그인을 마치지 못했습니다. 기기에 Google 계정이 있는지 확인해 주세요.'))));
      }
    } catch (_) {
      // 상세 오류는 화면에 보여주지 않는다 (SPEC §10)
      messenger.showSnackBar(SnackBar(content: Text(keepAll('로그인에 실패했습니다. 잠시 후 다시 시도해 주세요.'))));
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
        // Google 버튼과 약관 줄은 늘 화면 아래에 둔다. 위쪽(로고·소개)이 화면보다 길면 위쪽만 스크롤한다.
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final key = (box.biggest, MediaQuery.textScalerOf(context).scale(16));
                      if (key != _fittedFor) {
                        _fittedFor = key;
                        _fit = 0;
                        _demoScale = 1;
                        _fitLater();
                      }
                      Widget demo = KeyedSubtree(key: _demoKey, child: const SignInDemo());
                      if (_fit == 2 && _demoScale < 1) {
                        demo = SizedBox(
                          height: _demoHeight * _demoScale,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.topLeft,
                            child: SizedBox(width: box.maxWidth, child: demo),
                          ),
                        );
                      }
                      return SingleChildScrollView(
                        controller: _scroll,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minHeight: box.maxHeight),
                          child: IntrinsicHeight(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SizedBox(height: _fit == 0 ? 60 : 20),
                                const Align(alignment: Alignment.centerLeft, child: GwLogo(height: 56)),
                                const SizedBox(height: 28),
                                Semantics(
                                  header: true,
                                  child: Text(
                                    '귀띔이 맞춤 공고를\n먼저 안내해 드립니다',
                                    // 30pt 제목이라 큰 글자 설정에서는 1.2배까지만 키운다. 더 키우면 두 줄이 세 줄로 넘어간다.
                                    textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2),
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
                                  keepAll('학교 공지 중 나에게 맞는 공고를 골라 지원 조건·마감과 함께 정리합니다.'),
                                  style: TextStyle(fontSize: 16, height: 1.6, color: c.loginSub),
                                ),
                                SizedBox(height: _fit == 0 ? 36 : 20),
                                // 앱이 하는 일을 보여 주는 장면: 소식 말풍선 → 지원 전 체크리스트 → 관심 분야로 바뀌는 추천 순서
                                demo,
                                const Spacer(),
                                SizedBox(height: _fit == 0 ? 36 : 20),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                GoogleSignInButton(label: 'Google 계정으로 시작하기', onPressed: _busy ? null : _signIn),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.lock_outline_rounded, size: 15, color: c.loginSub),
                    const SizedBox(width: 6),
                    Text('성적·학번은 묻지 않습니다', style: TextStyle(fontSize: 13, color: c.loginSub)),
                  ],
                ),
                const SizedBox(height: 10),
                _TermsLine(color: c.loginSub, linkColor: c.loginInk),
              ],
            ),
          ),
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
          const TextSpan(text: '에 동의한 것으로 봅니다'),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}
