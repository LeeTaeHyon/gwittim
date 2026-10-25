import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 직접 그린 아이콘. 24 칸 안에 선 굵기 2, 끝과 꺾임은 둥글게 그린다.
/// 선 모양(고르지 않음)과 채운 모양(고름)이 한 벌씩 있다. 패키지를 들이지 않으려고 로고처럼 Path로 그린다.
enum GwGlyph {
  /// 오늘(홈): 로고와 같은 말풍선. 꼬리가 왼쪽 아래로 곧게 내려간다.
  today,

  /// 공고: 종이 한 장과 글줄 세 개
  notices,

  /// 저장함: 책갈피
  saved,

  /// 내 정보: 머리와 어깨
  profile,
}

class GwIcon extends StatelessWidget {
  const GwIcon(this.glyph, {super.key, this.filled = false, this.size = 24, this.color, this.semanticLabel});

  final GwGlyph glyph;
  final bool filled;
  final double size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? IconTheme.of(context).color ?? const Color(0xFF000000);
    final icon = CustomPaint(size: Size.square(size), painter: _GlyphPainter(glyph, filled, color));
    if (semanticLabel == null) return ExcludeSemantics(child: icon);
    return Semantics(label: semanticLabel, child: icon);
  }
}

/// 24 칸 좌표의 도형. 선 모양은 이 윤곽을 굵기 2로 긋고, 채운 모양은 윤곽을 칠한 뒤 글줄 같은 속을 비운다.
@visibleForTesting
Path glyphOutline(GwGlyph glyph) => switch (glyph) {
  GwGlyph.today =>
    Path()
      ..moveTo(8, 4)
      ..lineTo(16, 4)
      ..arcToPoint(const Offset(21, 9), radius: const Radius.circular(5))
      ..lineTo(21, 13)
      ..arcToPoint(const Offset(16, 18), radius: const Radius.circular(5))
      ..lineTo(7, 18)
      ..lineTo(3, 21)
      ..lineTo(3, 9)
      ..arcToPoint(const Offset(8, 4), radius: const Radius.circular(5))
      ..close(),
  GwGlyph.notices => Path()..addRRect(RRect.fromLTRBR(5, 3, 19, 21, const Radius.circular(3))),
  GwGlyph.saved =>
    Path()
      ..moveTo(8, 3.5)
      ..lineTo(16, 3.5)
      ..arcToPoint(const Offset(18, 5.5), radius: const Radius.circular(2))
      ..lineTo(18, 19.5)
      ..lineTo(12, 15.5)
      ..lineTo(6, 19.5)
      ..lineTo(6, 5.5)
      ..arcToPoint(const Offset(8, 3.5), radius: const Radius.circular(2))
      ..close(),
  GwGlyph.profile =>
    Path()
      ..addOval(Rect.fromCircle(center: const Offset(12, 8.5), radius: 3.75))
      ..moveTo(5, 20)
      ..arcToPoint(const Offset(19, 20), radius: const Radius.circular(7)),
};

/// 속에 그리는 선 (공고의 글줄)
List<(Offset, Offset)> _innerLines(GwGlyph glyph) => switch (glyph) {
  GwGlyph.notices => const [
    (Offset(9, 8.5), Offset(15, 8.5)),
    (Offset(9, 12), Offset(15, 12)),
    (Offset(9, 15.5), Offset(13, 15.5)),
  ],
  _ => const [],
};

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.filled, this.color);

  final GwGlyph glyph;
  final bool filled;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final outline = glyphOutline(glyph);
    final lines = _innerLines(glyph);
    if (!filled) {
      canvas.drawPath(outline, stroke);
      for (final (a, b) in lines) {
        canvas.drawLine(a, b, stroke);
      }
      return;
    }
    // 채운 모양: 윤곽을 굵기 2로 둘러 칠하고(선 모양과 크기가 같게), 글줄은 비운다.
    canvas.saveLayer(Offset.zero & const Size.square(24), Paint());
    if (glyph == GwGlyph.profile) {
      canvas.drawCircle(const Offset(12, 8.5), 4.75, Paint()..color = color);
      canvas.drawPath(
        Path()
          ..moveTo(4, 20)
          ..arcToPoint(const Offset(20, 20), radius: const Radius.circular(8))
          ..close(),
        Paint()..color = color,
      );
      canvas.drawPath(
        Path()
          ..moveTo(4, 20)
          ..lineTo(20, 20),
        stroke,
      );
    } else {
      canvas.drawPath(outline, Paint()..color = color);
      canvas.drawPath(outline, stroke);
    }
    final clear = Paint()
      ..blendMode = ui.BlendMode.clear
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (final (a, b) in lines) {
      canvas.drawLine(a, b, clear);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph || old.filled != filled || old.color != color;
}
