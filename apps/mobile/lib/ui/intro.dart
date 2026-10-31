import 'package:flutter/material.dart';

import 'logo.dart';
import 'theme.dart';

/// 앱 시작 인트로 (D-011). Android 시작 화면(네이비 바탕만)을 이어받아 말풍선이 꼬리 끝에서 튀어나오고,
/// '귀띔'을 한 획씩 채운 뒤 사라진다. 그동안 앱은 뒤에서 먼저 뜬다.
class Intro extends StatefulWidget {
  const Intro({super.key, required this.child});

  final Widget child;

  /// 인트로 말풍선 높이 (폭 150)
  static const logoHeight = 93.75;

  static const duration = Duration(milliseconds: 1250);

  @override
  State<Intro> createState() => _IntroState();
}

class _IntroState extends State<Intro> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: Intro.duration);

  // 처음 잠깐은 바탕만 둔다. 앱이 뒤에서 첫 화면을 그리느라 프레임이 밀려도 등장이 끊기지 않게.
  late final _pop = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.06, 0.32, curve: Cubic(0.34, 1.36, 0.64, 1)), // 끝에서 아주 살짝 넘쳤다 돌아온다
  );
  late final _popScale = Tween(begin: 0.4, end: 1.0).animate(_pop);
  late final _popOpacity = CurvedAnimation(parent: _controller, curve: const Interval(0.06, 0.2));
  late final _reveal = CurvedAnimation(parent: _controller, curve: const Interval(0.26, 0.7));
  late final _exit = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.78, 1, curve: Curves.easeOut),
  );
  late final _fade = ReverseAnimation(_exit);
  var _started = false;
  var _done = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // 애니메이션 줄이기 설정이면 인트로 없이 바로 앱을 보인다.
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) {
      _done = true;
      return;
    }
    // 첫 화면을 다 그린 뒤 시작한다. 뒤의 앱이 첫 화면을 만드는 동안(디버그 빌드는 몇 초) 시계가 먼저 흐르면
    // 그려지는 프레임 없이 인트로가 끝나 버린다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.forward().whenComplete(() {
        if (mounted) setState(() => _done = true);
      });
    });
  }

  @override
  void dispose() {
    _pop.dispose();
    _popOpacity.dispose();
    _reveal.dispose();
    _exit.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 테마 밖이라 고정 색을 쓴다: 앱 아이콘과 같은 네이비 바탕(라이트 로그인 바탕과 같음)과 라임 로고.
    return Stack(
      fit: StackFit.expand,
      textDirection: TextDirection.ltr,
      children: [
        widget.child,
        if (!_done)
          AnnotatedRegion(
            value: statusBarStyle(Brightness.dark),
            // 잠깐 보이는 장식이라 화면 읽기에서는 빼고, 뒤의 앱을 읽게 한다.
            child: ExcludeSemantics(
              child: FadeTransition(
                opacity: _fade,
                child: ColoredBox(
                  color: GwColors.light.loginBg,
                  child: Center(
                    // 말풍선은 꼬리 끝(왼쪽 아래)을 기준으로 커진다.
                    child: ScaleTransition(
                      scale: _popScale,
                      alignment: Alignment.bottomLeft,
                      child: FadeTransition(
                        opacity: _popOpacity,
                        child: GwLogo(height: Intro.logoHeight, reveal: _reveal),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
