import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import 'format.dart';
import 'theme.dart';

/// 칩 색 조합. 색은 테마 토큰에서 고른다.
enum PillTone { chip, neutral, point, urgent, check }

/// 둥근 칩 (분류·상태·D-day)
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.tone = PillTone.chip});

  final String label;
  final PillTone tone;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final (background, foreground) = switch (tone) {
      PillTone.chip => (c.chip, c.onChip),
      PillTone.neutral => (c.neutral, c.sub),
      PillTone.point => (c.point, c.onPoint),
      PillTone.urgent => (c.urgentSoft, c.urgent),
      PillTone.check => (c.checkSoft, c.check),
    };
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
  return Pill(label, tone: left <= 7 ? PillTone.urgent : PillTone.chip);
}

/// 목록의 조건 상태 칩. 확인 필요는 대부분의 공고에 붙으므로 회색으로 차분하게 (D-009).
Widget eligibilityPill(String status) => switch (status) {
  'met' => Pill(eligibilityShort(status)),
  _ => Pill(eligibilityShort(status), tone: PillTone.neutral),
};

/// '귀띔' 말풍선 배지
class GwBadge extends StatelessWidget {
  const GwBadge({super.key, this.small = false});

  final bool small;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final r = Radius.circular(small ? 11 : 14);
    return Container(
      height: small ? 22 : 28,
      padding: EdgeInsets.symmetric(horizontal: small ? 8 : 11),
      decoration: BoxDecoration(
        color: c.lime,
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
          style: TextStyle(fontSize: small ? 12 : 15, fontWeight: FontWeight.w700, color: c.limeInk),
        ),
      ),
    );
  }
}

/// 형광펜: 글자 아래쪽 58%만 칠한다. animate면 왼쪽에서 오른쪽으로 그어진다(애니메이션 줄이기 설정을 따름).
/// 색을 주지 않으면 테마의 형광펜 색(다크는 투명한 라임)을 쓴다.
class Marker extends StatelessWidget {
  const Marker(
    this.text, {
    super.key,
    this.style,
    this.color,
    this.animate = false,
    this.delay = Duration.zero,
  });

  final String text;
  final TextStyle? style;
  final Color? color;
  final bool animate;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? context.gw.marker;
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
InlineSpan markSpan(String text, TextStyle style, {Color? color}) => WidgetSpan(
  alignment: PlaceholderAlignment.baseline,
  baseline: TextBaseline.alphabetic,
  child: Marker(text, style: style, color: color),
);

/// 카드. bubble이면 말풍선 모양.
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
      color: context.gw.card,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// 화면 위쪽의 연두 말풍선 (귀띔 배지 + 한 줄 + 보조 문장). 저장·프로필 화면에서 쓴다.
class TipBubble extends StatelessWidget {
  const TipBubble({super.key, required this.title, this.detail, this.onTap});

  final String title;
  final String? detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    const radius = BorderRadius.only(
      topLeft: Radius.circular(22),
      topRight: Radius.circular(22),
      bottomRight: Radius.circular(22),
      bottomLeft: Radius.circular(6),
    );
    return Material(
      color: c.summary,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const GwBadge(small: true),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(fontSize: 15, height: 1.4, fontWeight: FontWeight.w600, color: c.body),
                          ),
                        ),
                      ],
                    ),
                    if (detail != null) ...[
                      const SizedBox(height: 6),
                      Text(detail!, style: TextStyle(fontSize: 13, height: 1.55, color: c.sub)),
                    ],
                  ],
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 8),
                Icon(Icons.chevron_right, size: 20, color: c.muted),
              ],
            ],
          ),
        ),
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
    final c = context.gw;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        backgroundColor: c.chip,
        foregroundColor: c.onChip,
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
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: context.gw.ink, letterSpacing: -0.5),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// 탭 화면 맨 위 제목 ("저장한 공고", "내 프로필")
class ScreenHeader extends StatelessWidget {
  const ScreenHeader(this.title, {super.key, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.6, color: c.ink),
                ),
              ),
            ),
            if (trailing != null) Text(trailing!, style: TextStyle(fontSize: 14, color: c.muted)),
          ],
        ),
      ),
    );
  }
}

/// 캡션 (13, 보조 글자)
TextStyle captionStyle(BuildContext context) => TextStyle(fontSize: 13, height: 1.6, color: context.gw.muted);

/// 하단 탭 하나. 고르면 icon 대신 activeIcon(채운 모양)을 쓴다.
typedef GwTab = ({IconData icon, IconData activeIcon, String label});

/// 바닥에 붙은 하단 탭 막대. 고른 탭은 채운 아이콘과 진한 색·굵은 글자로만 구분한다(2026-10-25 팀장 결정).
/// 색은 짧게 바뀌고, 누르는 동안 탭이 살짝 줄어든다(애니메이션 줄이기 설정을 따름).
class GwTabBar extends StatefulWidget {
  const GwTabBar({super.key, required this.tabs, required this.selected, required this.onSelect});

  final List<GwTab> tabs;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  State<GwTabBar> createState() => _GwTabBarState();
}

class _GwTabBarState extends State<GwTabBar> {
  /// 누르고 있는 탭
  int? _pressed;

  void _select(int i) {
    if (i != widget.selected) HapticFeedback.selectionClick();
    widget.onSelect(i);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final still = MediaQuery.maybeDisableAnimationsOf(context) == true;
    final duration = still ? Duration.zero : const Duration(milliseconds: 200);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3, // 큰 글자 설정에서도 막대 높이 안에 들어가게
      // 리플이 막대 바탕 위에 그려지도록 Material로 칠한다.
      child: Material(
        color: c.tab,
        shape: Border(top: BorderSide(color: c.line)),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 64,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, tab) in widget.tabs.indexed)
                  Expanded(
                    child: _TabButton(
                      tab,
                      selected: i == widget.selected,
                      pressed: i == _pressed,
                      duration: duration,
                      onPress: (down) => setState(() => _pressed = down ? i : null),
                      onTap: () => _select(i),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton(
    this.tab, {
    required this.selected,
    required this.pressed,
    required this.duration,
    required this.onPress,
    required this.onTap,
  });

  final GwTab tab;
  final bool selected;
  final bool pressed;
  final Duration duration;
  final ValueChanged<bool> onPress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: selected,
        // 누르는 동안 칸이 버튼처럼 둥근 사각형으로 칠해진다.
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            splashColor: c.tabActive.withValues(alpha: 0.10),
            highlightColor: c.tabActive.withValues(alpha: 0.08),
            onTapDown: (_) => onPress(true),
            onTapUp: (_) => onPress(false),
            onTapCancel: () => onPress(false),
            onTap: onTap,
            child: AnimatedScale(
              scale: pressed ? 0.92 : 1,
              duration: duration ~/ 2,
              curve: Curves.easeOut,
              child: TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: selected ? c.tabActive : c.onTab),
                duration: duration,
                builder: (context, color, _) => Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  spacing: 3,
                  children: [
                    AnimatedSwitcher(
                      duration: duration,
                      child: Icon(
                        selected ? tab.activeIcon : tab.icon,
                        key: ValueKey(selected),
                        size: 24,
                        color: color,
                      ),
                    ),
                    Text(
                      tab.label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                        color: color,
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
