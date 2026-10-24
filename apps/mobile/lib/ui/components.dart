import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import 'format.dart';
import 'logo.dart';
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

/// '귀띔' 말풍선 배지. 앱 로고(D-011)를 줄여 쓴다.
class GwBadge extends StatelessWidget {
  const GwBadge({super.key, this.small = false});

  final bool small;

  @override
  Widget build(BuildContext context) => GwLogo(height: small ? 22 : 28);
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

/// 하단 탭 하나
typedef GwTab = ({IconData icon, String label});

/// 떠 있는 캡슐 탭 막대 (목업 v2). 칸은 똑같이 나누고, 고른 탭에만 이름 폭에 맞춘 라임 캡슐을 둔다.
/// 탭을 바꾸면 캡슐이 미끄러져 옮겨 가고, 누르는 동안 살짝 작아진다(애니메이션 줄이기 설정을 따름).
/// Scaffold의 bottomNavigationBar에 extendBody와 함께 쓰고, 목록은 아래 여백(MediaQuery padding)만큼 비운다.
class GwTabBar extends StatefulWidget {
  const GwTabBar({super.key, required this.tabs, required this.selected, required this.onSelect});

  final List<GwTab> tabs;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  State<GwTabBar> createState() => _GwTabBarState();
}

class _GwTabBarState extends State<GwTabBar> {
  static const _gap = 4.0;
  static const _selectedLabel = TextStyle(fontSize: 14, fontWeight: FontWeight.w700);
  static const _label = TextStyle(fontSize: 12, fontWeight: FontWeight.w500);

  /// 누르고 있는 탭
  int? _pressed;

  /// 캡슐 폭: 좌우 여백 16 + 아이콘 20 + 간격 6 + 이름
  double _capsuleWidth(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: DefaultTextStyle.of(context).style.merge(_selectedLabel)),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = 16 + 20 + 6 + painter.width + 16;
    painter.dispose();
    return width;
  }

  void _select(int i) {
    if (i != widget.selected) HapticFeedback.selectionClick();
    widget.onSelect(i);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final still = MediaQuery.maybeDisableAnimationsOf(context) == true;
    Duration ms(int milliseconds) => still ? Duration.zero : Duration(milliseconds: milliseconds);
    // 제스처 막대나 버튼 영역이 있으면 그 위로 조금 띄운다.
    final bottom = math.max(MediaQuery.paddingOf(context).bottom + 8, 20.0);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3, // 큰 글자 설정에서도 막대 높이 안에 들어가게
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, bottom),
        child: Container(
          height: 62,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: c.tab,
            borderRadius: BorderRadius.circular(31),
            boxShadow: [BoxShadow(color: c.tabShadow, blurRadius: 24, offset: const Offset(0, 10))],
          ),
          child: LayoutBuilder(
            builder: (context, box) {
              final count = widget.tabs.length;
              final slot = (box.maxWidth - _gap * (count - 1)) / count;
              final width = math.min(_capsuleWidth(context, widget.tabs[widget.selected].label), slot);
              return Stack(
                children: [
                  AnimatedPositioned(
                    duration: ms(280),
                    curve: Curves.easeOutCubic,
                    left: widget.selected * (slot + _gap) + (slot - width) / 2,
                    width: width,
                    top: 0,
                    bottom: 0,
                    child: AnimatedScale(
                      scale: _pressed == widget.selected ? 0.94 : 1,
                      duration: ms(120),
                      curve: Curves.easeOut,
                      child: DecoratedBox(
                        key: const ValueKey('tab-capsule'),
                        decoration: BoxDecoration(color: c.lime, borderRadius: BorderRadius.circular(25)),
                      ),
                    ),
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: _gap,
                    children: [
                      for (final (i, tab) in widget.tabs.indexed)
                        Expanded(
                          child: _TabButton(
                            tab,
                            selected: i == widget.selected,
                            pressed: i == _pressed,
                            duration: ms(200),
                            onPress: (down) => setState(() => _pressed = down ? i : null),
                            onTap: () => _select(i),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
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
    final color = selected ? c.limeInk : c.onTab;
    final icon = Icon(tab.icon, size: 20, color: color);
    // 고른 탭은 아이콘 옆에, 나머지는 아이콘 아래에 이름. 바뀔 때 겹쳐 흐려지며 넘어간다.
    final content = selected
        ? Row(
            key: const ValueKey(true),
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 6,
            children: [icon, Text(tab.label, style: _GwTabBarState._selectedLabel.copyWith(color: color))],
          )
        : Column(
            key: const ValueKey(false),
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 2,
            children: [icon, Text(tab.label, style: _GwTabBarState._label.copyWith(color: color))],
          );
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: selected,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => onPress(true),
          onTapUp: (_) => onPress(false),
          onTapCancel: () => onPress(false),
          onTap: onTap,
          child: AnimatedScale(
            scale: pressed ? (selected ? 0.94 : 0.88) : 1, // 고른 탭은 캡슐과 같이 줄어든다
            duration: duration ~/ 2,
            curve: Curves.easeOut,
            child: AnimatedSwitcher(duration: duration, child: content),
          ),
        ),
      ),
    );
  }
}
