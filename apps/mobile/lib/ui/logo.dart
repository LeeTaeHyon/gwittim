import 'package:flutter/material.dart';

import 'theme.dart';

/// 귀띔 로고 (D-011 A1). 라임 말풍선 안에 직접 그린 '귀띔'으로, 글꼴을 쓰지 않는다.
/// 색은 라이트·다크 모두 라임 면 위 네이비 글자다.
class GwLogo extends StatelessWidget {
  const GwLogo({super.key, required this.height, this.reveal});

  /// 꼬리까지 포함한 높이. 너비는 원본 비율(400:250)을 따른다.
  final double height;

  /// 글자 획을 차례로 채우는 진행도(0~1). 시작 인트로에서만 쓰고, 없으면 글자를 다 그린다.
  final Animation<double>? reveal;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Semantics(
      label: '귀띔',
      child: CustomPaint(size: Size(height * 400 / 250, height), painter: _LogoPainter(c.lime, c.limeInk, reveal)),
    );
  }
}

/// 글자 없는 로고 말풍선. 오류·빈 화면의 그림과 로딩 표시에 쓴다.
/// dots가 있으면 말풍선 안에 점 세 개를 차례로 깜빡인다(0~1 반복 진행도).
class GwBubbleMark extends StatelessWidget {
  const GwBubbleMark({super.key, required this.height, required this.color, this.dotColor, this.dots});

  final double height;
  final Color color;
  final Color? dotColor;
  final Animation<double>? dots;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(height * 400 / 250, height), painter: _BubblePainter(color, dotColor, dots));
  }
}

class _BubblePainter extends CustomPainter {
  _BubblePainter(this.color, this.dotColor, this.dots) : super(repaint: dots);

  final Color color;
  final Color? dotColor;
  final Animation<double>? dots;

  static final _bubble = svgPath(logoBubbleData);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 400, size.height / 250);
    canvas.drawPath(_bubble, Paint()..color = color);
    final dotColor = this.dotColor;
    if (dotColor == null) return;
    // 점 하나가 밝아졌다 흐려지는 동안 다음 점이 이어서 밝아진다.
    final t = dots?.value;
    for (var i = 0; i < 3; i++) {
      var alpha = 1.0;
      if (t != null) {
        final phase = ((t - i * 0.2) % 1 + 1) % 1;
        alpha = 0.3 + 0.7 * (phase < 0.4 ? Curves.easeInOut.transform(1 - (phase - 0.2).abs() / 0.2) : 0);
      }
      canvas.drawCircle(Offset(130 + i * 70.0, 110), 22, Paint()..color = dotColor.withValues(alpha: alpha));
    }
  }

  @override
  bool shouldRepaint(_BubblePainter old) => old.color != color || old.dotColor != dotColor || old.dots != dots;
}

/// `docs/brand/logo.svg`의 path 데이터 (viewBox 0 0 400 250). 원본을 고치면 여기도 같이 고친다.
@visibleForTesting
const logoBubbleData = 'M56 0H344A56 56 0 0 1 400 56V164A56 56 0 0 1 344 220H40L0 250V56A56 56 0 0 1 56 0Z';

/// 글자는 원본에서 translate(72 40) scale(1.15)로 놓인다.
@visibleForTesting
const logoGlyphData =
    'M2 6H64V42H51V17H2ZM0 56H80V67H47V116H34V67H0ZM86 0H100V120H86Z'
    'M118 4H150V14H130V30H152V40H118ZM160 4H192V14H172V30H194V40H160Z'
    'M118 56H200V66H118ZM208 0H222V68H208Z'
    'M130 78H214A8 8 0 0 1 222 86V112A8 8 0 0 1 214 120H132L122 128V86A8 8 0 0 1 130 78Z'
    'M136 88A2 2 0 0 0 134 90V110H208A2 2 0 0 0 210 108V90A2 2 0 0 0 208 88Z';

/// 획 단위(ㄱ ㅜ ㅣ ㄷ ㄷ ㅡ ㅣ ㅁ). ㅁ은 바깥과 속을 한 path로 둬야 속이 빈다.
final _strokes = () {
  final parts = RegExp('M[^M]*').allMatches(logoGlyphData).map((m) => m[0]!).toList();
  return [for (final d in parts.take(7)) svgPath(d), svgPath(parts.skip(7).join())];
}();

class _LogoPainter extends CustomPainter {
  _LogoPainter(this.bubble, this.ink, this.reveal) : super(repaint: reveal);

  final Color bubble;
  final Color ink;
  final Animation<double>? reveal;

  static final _bubble = svgPath(logoBubbleData);
  static final _glyph = svgPath(logoGlyphData);

  /// 획 하나가 나타나는 데 쓰는 몫. 나머지만큼 획마다 시작이 늦어진다.
  static const _span = 0.35;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 400, size.height / 250);
    canvas.drawPath(_bubble, Paint()..color = bubble);
    canvas.translate(72, 40);
    canvas.scale(1.15);
    final r = reveal?.value;
    if (r == null) {
      canvas.drawPath(_glyph, Paint()..color = ink);
      return;
    }
    // 쓰는 순서대로 한 획씩 아래에서 살짝 올라오며 나타난다.
    for (var i = 0; i < _strokes.length; i++) {
      final start = i * (1 - _span) / (_strokes.length - 1);
      final t = Curves.easeOutCubic.transform(((r - start) / _span).clamp(0.0, 1.0));
      if (t == 0) continue;
      canvas.save();
      canvas.translate(0, (1 - t) * 10);
      canvas.drawPath(_strokes[i], Paint()..color = ink.withValues(alpha: t));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_LogoPainter old) => old.bubble != bubble || old.ink != ink || old.reveal != reveal;
}

/// 로고에 쓰는 절대 좌표 명령(M·L·H·V·A·Z)만 읽는다. 로고 하나라서 SVG 패키지를 들이지 않는다.
/// A의 sweep 1(시계 방향)은 arcToPoint의 clockwise와 같다.
@visibleForTesting
Path svgPath(String d) {
  final tokens = RegExp(r'[A-Za-z]|[\d.]+').allMatches(d).map((m) => m[0]!).toList();
  final path = Path();
  var i = 0;
  var x = 0.0;
  var y = 0.0;
  String? command;
  double next() => double.parse(tokens[i++]);
  while (i < tokens.length) {
    if (double.tryParse(tokens[i]) == null) command = tokens[i++];
    switch (command) {
      case 'M':
        x = next();
        y = next();
        path.moveTo(x, y);
      case 'L':
        x = next();
        y = next();
        path.lineTo(x, y);
      case 'H':
        x = next();
        path.lineTo(x, y);
      case 'V':
        y = next();
        path.lineTo(x, y);
      case 'A':
        final radius = Radius.elliptical(next(), next());
        final rotation = next();
        final largeArc = next() != 0;
        final clockwise = next() != 0;
        x = next();
        y = next();
        path.arcToPoint(Offset(x, y), radius: radius, rotation: rotation, largeArc: largeArc, clockwise: clockwise);
      case 'Z':
        path.close();
        command = null; // Z 뒤에는 새 명령이 와야 한다
      default:
        throw FormatException('지원하지 않는 path 명령', d, i);
    }
  }
  return path;
}
