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
                      // 앱이 알려 주는 소식의 예시 (D-010). 채팅처럼 하나씩 도착하는 장면을 되풀이한다.
                      const _ExampleDemo(),
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

/// 로그인 화면의 예시 말풍선 장면. 말풍선마다 '…' 입력 중 표시가 잠깐 보인 뒤 말풍선이 꼬리 쪽에서
/// 톡 튀어나온다. 셋이 다 나오면 잠시 머물렀다가 함께 흐려지고, 다음 세트로 넘어가 되풀이한다.
/// 크기·투명도만 바꾸고 자리는 가장 큰 세트만큼 늘 차지해서 아래 버튼이 움직이지 않는다.
/// 애니메이션 줄이기 설정이면 1세트가 그대로 보인다.
/// 문구는 앱에 실제로 있는 기능만 쓰고 알림은 약속하지 않는다(푸시 알림은 P0 제외).
class _ExampleDemo extends StatefulWidget {
  const _ExampleDemo();

  @override
  State<_ExampleDemo> createState() => _ExampleDemoState();
}

/// 세트 하나(ms). 말풍선 i의 입력 중 표시는 300 + 900i에 시작해 600 뒤에 말풍선으로 바뀐다.
const _demoLoop = 7000;
const _demoSets = 3;
const _demoPop = 450;
const _demoFadeOut = 6200;

class _ExampleDemoState extends State<_ExampleDemo> with SingleTickerProviderStateMixin {
  late final _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _demoLoop * _demoSets),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) {
      _loop.stop();
    } else if (!_loop.isAnimating) {
      _loop.repeat();
    }
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  /// 살짝 넘쳤다 돌아오는 등장 곡선 (시작 인트로의 말풍선과 같은 느낌)
  static const _pop = Cubic(0.34, 1.4, 0.64, 1);

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final still = MediaQuery.maybeDisableAnimationsOf(context) == true;
    final sets = [
      // 1세트: 마감·맞춤 공고·저장 공고 변경
      [
        _ExampleBubble(kicker: '마감 임박', kickerColor: c.urgent, text: '장학생 선발 공고 · D-6'),
        _ExampleBubble(kicker: '맞춤 공고', kickerColor: c.accent, text: '관심 분야와 관련된 공고 ', marked: '3개'),
        _ExampleBubble(kicker: '저장한 공고', kickerColor: c.accent, text: '발표회 마감이 3일 늦춰졌어요'),
      ],
      // 2세트: 지원 조건 비교 (성적은 받지 않아서 직접 확인)
      [
        _ExampleBubble(kicker: '지원 조건', kickerColor: c.accent, text: '학과·학년 조건이 ', marked: '맞아요'),
        _ExampleBubble(kicker: '직접 확인', kickerColor: c.accent, text: '평점 조건은 공지에서 확인해요'),
        _ExampleBubble(kicker: '마감 임박', kickerColor: c.urgent, text: '공모전 접수 · 오늘 마감'),
      ],
      // 3세트: 오늘의 귀띔·추천 이유·선착순
      [
        _ExampleBubble(kicker: '오늘의 귀띔', kickerColor: c.accent, text: '오늘 챙길 소식 ', marked: '2가지'),
        _ExampleBubble(kicker: '추천 이유', kickerColor: c.accent, text: '희망 직무와 관련 있어요'),
        _ExampleBubble(kicker: '선착순', kickerColor: c.accent, text: '해외 연수 · 정원 차면 마감돼요'),
      ],
    ];
    const indents = [0.0, 32.0, 12.0];
    return AnimatedBuilder(
      animation: _loop,
      builder: (context, _) {
        final all = _loop.value * _demoLoop * _demoSets;
        final set = still ? 0 : (all ~/ _demoLoop).clamp(0, _demoSets - 1);
        final ms = still ? _demoFadeOut.toDouble() : all - set * _demoLoop;
        final out = Curves.easeInCubic.transform(((ms - _demoFadeOut) / 500).clamp(0.0, 1.0));
        return Opacity(
          opacity: 1 - out,
          alwaysIncludeSemantics: true,
          child: Transform.translate(
            offset: Offset(0, -10 * out),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < indents.length; i++) ...[
                  if (i > 0) const SizedBox(height: 10),
                  Padding(
                    padding: EdgeInsets.only(left: indents[i]),
                    child: _slot([for (final s in sets) s[i]], set, ms - (300 + 900 * i)),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// 세트마다 이 자리에 오는 말풍선 중 지금 세트의 것만 보인다. 나머지는 자리만 차지한다(가장 큰 것에 맞춤).
  /// t: 이 말풍선의 입력 중 표시가 시작된 뒤 지난 ms
  Widget _slot(List<Widget> bubbles, int set, double t) {
    final typing = t < 0 || t >= 600 ? 0.0 : (t / 150).clamp(0.0, 1.0) * ((600 - t) / 150).clamp(0.0, 1.0);
    final p = ((t - 600) / _demoPop).clamp(0.0, 1.0);
    return Stack(
      alignment: Alignment.bottomLeft,
      children: [
        for (var k = 0; k < bubbles.length; k++)
          if (k != set)
            Visibility(
              visible: false,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: bubbles[k],
            ),
        Opacity(
          opacity: Curves.easeOut.transform((p * 2).clamp(0.0, 1.0)),
          alwaysIncludeSemantics: true,
          child: Transform.scale(
            scale: 0.6 + 0.4 * _pop.transform(p),
            alignment: Alignment.bottomLeft,
            child: bubbles[set],
          ),
        ),
        if (typing > 0)
          Opacity(
            opacity: typing,
            child: _TypingBubble(t: t),
          ),
      ],
    );
  }
}

/// 말풍선이 오기 전의 '…' 입력 중 표시. 점 세 개가 차례로 밝아진다.
class _TypingBubble extends StatelessWidget {
  const _TypingBubble({required this.t});

  final double t;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return ExcludeSemantics(
      child: Container(
        key: const ValueKey('typing'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: c.loginCard,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
            bottomRight: Radius.circular(20),
            bottomLeft: Radius.circular(6),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.muted.withValues(
                    alpha: 0.35 + 0.65 * (1 - (((t / 400 - i * 0.2) % 1) - 0.3).abs() / 0.7).clamp(0.0, 1.0),
                  ),
                ),
              ),
          ],
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
            Text(
              kicker,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: kickerColor),
            ),
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
