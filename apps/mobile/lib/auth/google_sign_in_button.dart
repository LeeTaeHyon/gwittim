import 'package:flutter/material.dart';

/// Google 로그인 버튼 (Google Sign-In 브랜딩 가이드, Light 테마).
/// 색·테두리·여백은 가이드 값이라 앱 테마 토큰을 쓰지 않는다:
/// 흰 바탕, #747775 1px 안쪽 테두리, #1F1F1F 글자, 표준 'G' 로고(크기·색 변경 금지), 왼쪽 12 / 로고 뒤 10 / 글자 뒤 12.
/// 글꼴은 가이드의 Google Sans 대신 Android 기본 글꼴(Roboto)을 쓴다.
class GoogleSignInButton extends StatelessWidget {
  const GoogleSignInButton({super.key, required this.label, required this.onPressed});

  final String label;

  /// null이면 비활성 (가이드: 내용 38% 불투명)
  final VoidCallback? onPressed;

  static const _fill = Color(0xFFFFFFFF);
  static const _stroke = Color(0xFF747775);
  static const _text = Color(0xFF1F1F1F);

  @override
  Widget build(BuildContext context) {
    const shape = StadiumBorder(side: BorderSide(color: _stroke));
    return Semantics(
      button: true,
      enabled: onPressed != null,
      child: Material(
        color: _fill,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          customBorder: shape,
          child: SizedBox(
            height: 56,
            child: Opacity(
              opacity: onPressed == null ? 0.38 : 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const GoogleLogo(size: 20),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Roboto',
                          fontSize: 14,
                          height: 20 / 14,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.25,
                          color: _text,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 표준 컬러 'G' 로고. Google 로그인 버튼 안에서만 쓴다 (가이드: 다른 용도는 별도 허락 필요).
/// 경로는 Google 로그인 버튼 공식 SVG(48×48)를 그대로 옮겼다.
class GoogleLogo extends StatelessWidget {
  const GoogleLogo({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(size: Size.square(size), painter: const _GoogleLogoPainter()),
    );
  }
}

class _GoogleLogoPainter extends CustomPainter {
  const _GoogleLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 48, size.height / 48);
    final red = Path()
      ..moveTo(24, 9.5)
      ..relativeCubicTo(3.54, 0, 6.71, 1.22, 9.21, 3.6)
      ..relativeLineTo(6.85, -6.85)
      ..cubicTo(35.9, 2.38, 30.47, 0, 24, 0)
      ..cubicTo(14.62, 0, 6.51, 5.38, 2.56, 13.22)
      ..relativeLineTo(7.98, 6.19)
      ..cubicTo(12.43, 13.72, 17.74, 9.5, 24, 9.5)
      ..close();
    final blue = Path()
      ..moveTo(46.98, 24.55)
      ..relativeCubicTo(0, -1.57, -0.15, -3.09, -0.38, -4.55)
      ..lineTo(24, 20)
      ..relativeLineTo(0, 9.02)
      ..relativeLineTo(12.94, 0)
      ..relativeCubicTo(-0.58, 2.96, -2.26, 5.48, -4.78, 7.18)
      ..relativeLineTo(7.73, 6)
      ..relativeCubicTo(4.51, -4.18, 7.09, -10.36, 7.09, -17.65)
      ..close();
    final yellow = Path()
      ..moveTo(10.53, 28.59)
      ..relativeCubicTo(-0.48, -1.45, -0.76, -2.99, -0.76, -4.59)
      // SVG 's': 첫 제어점은 직전 제어점을 현재 점에 대해 뒤집은 것
      ..relativeCubicTo(0, -1.6, 0.27, -3.14, 0.76, -4.59)
      ..relativeLineTo(-7.98, -6.19)
      ..cubicTo(0.92, 16.46, 0, 20.12, 0, 24)
      ..relativeCubicTo(0, 3.88, 0.92, 7.54, 2.56, 10.78)
      ..relativeLineTo(7.97, -6.19)
      ..close();
    final green = Path()
      ..moveTo(24, 48)
      ..relativeCubicTo(6.48, 0, 11.93, -2.13, 15.89, -5.81)
      ..relativeLineTo(-7.73, -6)
      ..relativeCubicTo(-2.15, 1.45, -4.92, 2.3, -8.16, 2.3)
      ..relativeCubicTo(-6.26, 0, -11.57, -4.22, -13.47, -9.91)
      ..relativeLineTo(-7.98, 6.19)
      ..cubicTo(6.51, 42.62, 14.62, 48, 24, 48)
      ..close();
    canvas
      ..drawPath(red, Paint()..color = const Color(0xFFEA4335))
      ..drawPath(blue, Paint()..color = const Color(0xFF4285F4))
      ..drawPath(yellow, Paint()..color = const Color(0xFFFBBC05))
      ..drawPath(green, Paint()..color = const Color(0xFF34A853));
  }

  @override
  bool shouldRepaint(_GoogleLogoPainter oldDelegate) => false;
}
