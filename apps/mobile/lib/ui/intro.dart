import 'package:flutter/material.dart';

import 'logo.dart';
import 'theme.dart';

/// 앱 시작 인트로 (D-011). Android 시작 화면의 빈 말풍선을 같은 자리·크기로 이어받아
/// '귀띔'을 한 획씩 채운 뒤 사라진다. 그동안 앱은 뒤에서 먼저 뜬다.
class Intro extends StatefulWidget {
  const Intro({super.key, required this.child});

  final Widget child;

  /// `android/app/src/main/res/drawable/splash_bubble.xml`의 말풍선과 같은 크기 (폭 150dp)
  static const logoHeight = 93.75;

  static const duration = Duration(milliseconds: 1100);

  @override
  State<Intro> createState() => _IntroState();
}

class _IntroState extends State<Intro> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: Intro.duration);
  late final _reveal = CurvedAnimation(parent: _controller, curve: const Interval(0.08, 0.62));
  late final _exit = CurvedAnimation(parent: _controller, curve: const Interval(0.75, 1, curve: Curves.easeOut));
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
    _controller.forward().whenComplete(() {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  void dispose() {
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
                    child: GwLogo(height: Intro.logoHeight, reveal: _reveal),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
