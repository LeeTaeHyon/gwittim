import 'package:flutter/material.dart';

import '../data/models.dart';
import 'format.dart';
import 'theme.dart';

/// 둥근 칩 (분류·상태·D-day)
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.background = Gw.navySoft, this.foreground = Gw.navy});

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(13)),
      child: Center(
        widthFactor: 1,
        child: Text(
          label,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: foreground),
        ),
      ),
    );
  }
}

/// 7일 이내 마감은 빨강, 그 외 네이비. 확정 마감이 없으면 칩을 만들지 않는다.
Widget? ddayPill(NoticeSummary n, DateTime today) {
  final left = daysLeft(n, today);
  if (left == null) return null;
  final label = left == 0 ? '오늘 마감' : 'D-$left';
  return left <= 7 ? Pill(label, background: Gw.urgentSoft, foreground: Gw.urgent) : Pill(label);
}

/// 목록의 조건 상태 칩. 확인 필요는 대부분의 공고에 붙으므로 회색으로 차분하게 (D-009).
Widget eligibilityPill(String status) => switch (status) {
  'met' => Pill(eligibilityShort(status)),
  _ => Pill(eligibilityShort(status), background: Gw.bg, foreground: Gw.sub),
};

/// '귀띔' 말풍선 배지
class GwBadge extends StatelessWidget {
  const GwBadge({super.key, this.small = false});

  final bool small;

  @override
  Widget build(BuildContext context) {
    final r = Radius.circular(small ? 11 : 14);
    return Container(
      height: small ? 22 : 28,
      padding: EdgeInsets.symmetric(horizontal: small ? 8 : 11),
      decoration: BoxDecoration(
        color: Gw.lime,
        borderRadius: BorderRadius.only(
          topLeft: r,
          topRight: r,
          bottomRight: r,
          bottomLeft: Radius.circular(small ? 3 : 4),
        ),
      ),
      child: Center(
        widthFactor: 1,
        child: Text(
          '귀띔',
          style: TextStyle(fontSize: small ? 12 : 15, fontWeight: FontWeight.w700, color: Gw.limeInk),
        ),
      ),
    );
  }
}

/// 형광펜: 글자 아래쪽 58%만 칠한다. animate면 왼쪽에서 오른쪽으로 그어진다(애니메이션 줄이기 설정을 따름).
class Marker extends StatelessWidget {
  const Marker(
    this.text, {
    super.key,
    this.style,
    this.color = Gw.lime,
    this.animate = false,
    this.delay = Duration.zero,
  });

  final String text;
  final TextStyle? style;
  final Color color;
  final bool animate;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    final child = Text(text, style: style);
    if (!animate || MediaQuery.maybeDisableAnimationsOf(context) == true) {
      return CustomPaint(painter: _MarkerPainter(color, 1), child: child);
    }
    final total = 700 + delay.inMilliseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay.inMilliseconds / total, 1, curve: Curves.easeOutCubic),
      builder: (_, t, c) => CustomPaint(painter: _MarkerPainter(color, t), child: c),
      child: child,
    );
  }
}

class _MarkerPainter extends CustomPainter {
  _MarkerPainter(this.color, this.progress);

  final Color color;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final top = size.height * 0.42;
    canvas.drawRect(Rect.fromLTWH(0, top, size.width * progress, size.height - top), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_MarkerPainter old) => old.progress != progress || old.color != color;
}

/// 문장 속 형광펜 조각. 짧은 낱말에만 쓴다 (조각 안에서는 줄바꿈되지 않음).
InlineSpan markSpan(String text, TextStyle style, {Color color = Gw.lime}) => WidgetSpan(
  alignment: PlaceholderAlignment.baseline,
  baseline: TextBaseline.alphabetic,
  child: Marker(text, style: style, color: color),
);

/// 흰 카드. bubble이면 말풍선 모양.
class GwCard extends StatelessWidget {
  const GwCard({
    super.key,
    required this.child,
    this.bubble = false,
    this.padding = const EdgeInsets.all(20),
    this.onTap,
  });

  final Widget child;
  final bool bubble;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final radius = bubble ? Gw.bubble : BorderRadius.circular(20);
    return Material(
      color: Colors.white,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// 카드 안 작은 보조 버튼 ("공고 보기 >")
class SoftButton extends StatelessWidget {
  const SoftButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        backgroundColor: Gw.navySoft,
        foregroundColor: Gw.navy,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: const StadiumBorder(),
        textStyle: Theme.of(context).textTheme.labelLarge!
            .copyWith(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [Text(label), const SizedBox(width: 2), const Icon(Icons.chevron_right, size: 18)],
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Gw.ink, letterSpacing: -0.5),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

const captionStyle = TextStyle(fontSize: 13, height: 1.6, color: Gw.muted);
