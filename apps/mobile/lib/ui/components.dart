import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import 'format.dart';
import 'icons.dart';
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
  const Marker(this.text, {super.key, this.style, this.color, this.animate = false, this.delay = Duration.zero});

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
                      Text(keepAll(detail!), style: TextStyle(fontSize: 13, height: 1.55, color: c.sub)),
                    ],
                  ],
                ),
              ),
              if (onTap != null) ...[const SizedBox(width: 8), Icon(Icons.chevron_right_rounded, size: 20, color: c.muted)],
            ],
          ),
        ),
      ),
    );
  }
}

/// 카드 안 작은 보조 버튼 ("공고 보기 >")
class SoftButton extends StatelessWidget {
  const SoftButton({super.key, required this.label, required this.onPressed, this.icon = Icons.chevron_right_rounded});

  final String label;
  final VoidCallback onPressed;

  /// 글자 뒤 아이콘. null이면 글자만.
  final IconData? icon;

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
        children: [
          Text(label),
          if (icon != null) ...[const SizedBox(width: 2), Icon(icon, size: 18)],
        ],
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

/// 하단 탭 하나. 고르면 채운 아이콘을 쓴다.
typedef GwTab = ({GwGlyph glyph, String label});

/// 고른 탭 아이콘 아래 라임 점의 위쪽 위치 (아이콘 8~32, 이름 42~)
const _dotTop = 35.0;

/// 바닥에 붙은 하단 탭 막대. 고른 탭은 채운 아이콘과 진한 색·굵은 글자, 아이콘 아래 라임 점으로 구분한다.
/// 누르면 아이콘 둘레가 칠해졌다가 천천히 사라지고, 색과 아이콘은 부드럽게 바뀐다. 점은 고른 탭으로
/// 옮겨 가며 가로로 늘었다 줄어든다(애니메이션 줄이기 설정을 따름).
class GwTabBar extends StatefulWidget {
  const GwTabBar({super.key, required this.tabs, required this.selected, required this.onSelect});

  final List<GwTab> tabs;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  State<GwTabBar> createState() => _GwTabBarState();
}

class _GwTabBarState extends State<GwTabBar> with SingleTickerProviderStateMixin {
  /// 누르고 있는 탭
  int? _pressed;

  /// 점이 떠난 탭
  late int _from = widget.selected;
  late final _dot = AnimationController(vsync: this, duration: const Duration(milliseconds: 320), value: 1);

  @override
  void didUpdateWidget(GwTabBar old) {
    super.didUpdateWidget(old);
    if (old.selected == widget.selected) return;
    _from = old.selected;
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) {
      _dot.value = 1;
    } else {
      _dot.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _dot.dispose();
    super.dispose();
  }

  void _select(int i) {
    if (i != widget.selected) HapticFeedback.selectionClick();
    widget.onSelect(i);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final still = MediaQuery.maybeDisableAnimationsOf(context) == true;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3, // 큰 글자 설정에서도 막대 높이 안에 들어가게
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.tab,
          border: Border(top: BorderSide(color: c.line)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 64,
            child: LayoutBuilder(
              builder: (context, box) {
                final slot = box.maxWidth / widget.tabs.length;
                return Stack(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (i, tab) in widget.tabs.indexed)
                          Expanded(
                            child: _TabButton(
                              tab,
                              selected: i == widget.selected,
                              pressed: i == _pressed,
                              still: still,
                              onPress: (down) => setState(() => _pressed = down ? i : null),
                              onTap: () => _select(i),
                            ),
                          ),
                      ],
                    ),
                    AnimatedBuilder(
                      animation: _dot,
                      builder: (context, _) {
                        final t = _dot.value;
                        final x = slot * (_from + (widget.selected - _from) * Curves.easeOutCubic.transform(t) + 0.5);
                        final width = 4 + 8 * math.sin(math.pi * t);
                        return Positioned(
                          key: const ValueKey('tab-dot'),
                          top: _dotTop,
                          left: x - width / 2,
                          width: width,
                          height: 4,
                          child: DecoratedBox(
                            decoration: BoxDecoration(color: c.lime, borderRadius: BorderRadius.circular(2)),
                          ),
                        );
                      },
                    ),
                  ],
                );
              },
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
    required this.still,
    required this.onPress,
    required this.onTap,
  });

  final GwTab tab;
  final bool selected;
  final bool pressed;

  /// 애니메이션 줄이기 설정
  final bool still;
  final ValueChanged<bool> onPress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    Duration ms(int milliseconds) => still ? Duration.zero : Duration(milliseconds: milliseconds);
    // 누를 때는 빠르게, 뗄 때와 색이 바뀔 때는 천천히
    final change = ms(320);
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
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 누르는 동안 아이콘과 이름 둘레가 버튼처럼 둥근 사각형으로 칠해진다. 누르는 자리는 칸 전체.
              AnimatedContainer(
                duration: pressed ? ms(90) : ms(450),
                curve: pressed ? Curves.easeOut : Curves.easeOutCubic,
                width: 72,
                height: 52,
                decoration: BoxDecoration(
                  color: c.tabActive.withValues(alpha: pressed ? 0.10 : 0),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              AnimatedScale(
                scale: pressed ? 0.92 : 1,
                duration: pressed ? ms(120) : ms(360),
                curve: pressed ? Curves.easeOut : Curves.easeOutCubic,
                child: TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: selected ? c.tabActive : c.onTab),
                  duration: change,
                  curve: Curves.easeOutCubic,
                  // 아이콘 위치를 정해 두어야 막대에 걸친 점이 아이콘 바로 아래에 온다.
                  builder: (context, color, _) => Column(
                    children: [
                      const SizedBox(height: 8),
                      AnimatedSwitcher(
                        duration: change,
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        child: GwIcon(tab.glyph, key: ValueKey(selected), filled: selected, color: color),
                      ),
                      const SizedBox(height: 10),
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
            ],
          ),
        ),
      ),
    );
  }
}

/// 화면이 들어오고 나가는 움직임. 탭 전환과 같은 곡선과 시간(320ms)을 쓴다.
/// 옆 화면(공고 리포트)은 오른쪽에서 48 밀려 들어오며 나타나고, rise면(하루 첫 브리핑) 아래에서 올라온다.
Widget gwTransition(Animation<double> animation, Widget child, {bool rise = false}) {
  return AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) {
      final raw = animation.value;
      final t = Curves.easeOutCubic.transform(raw);
      final shift = 48 * (1 - t);
      return Opacity(
        opacity: Curves.easeOut.transform(((raw - 0.1) / 0.9).clamp(0.0, 1.0)),
        child: Transform.translate(offset: rise ? Offset(0, shift) : Offset(shift, 0), child: child),
      );
    },
  );
}

/// 공통 화면 이동. 애니메이션 줄이기 설정이면 바로 바뀐다.
Route<T> gwRoute<T>(BuildContext context, WidgetBuilder builder, {bool rise = false}) {
  final duration = MediaQuery.maybeDisableAnimationsOf(context) == true
      ? Duration.zero
      : const Duration(milliseconds: 320);
  return PageRouteBuilder<T>(
    fullscreenDialog: rise,
    transitionDuration: duration,
    reverseTransitionDuration: duration,
    pageBuilder: (context, _, _) => builder(context),
    transitionsBuilder: (_, animation, _, child) => gwTransition(animation, child, rise: rise),
  );
}

/// 테마의 기본 화면 이동도 gwRoute와 같게 둔다. 아래에 깔린 화면은 움직이지 않는다.
class GwPageTransitions extends PageTransitionsBuilder {
  const GwPageTransitions();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => gwTransition(animation, child, rise: route.fullscreenDialog);
}

/// 화면 위 막대. 스크롤하기 전에는 비어 있고, 내용이 막대 밑으로 들어가면 card 바탕과 구분선이 생기며
/// title이 한 줄로 나타난다. onClose가 있으면 오른쪽에 닫기(✕), 없으면 왼쪽에 뒤로(←).
class GwTopBar extends StatefulWidget implements PreferredSizeWidget {
  const GwTopBar({super.key, this.title, this.onClose, this.closeLabel = '닫기', this.actions = const []});

  final String? title;
  final VoidCallback? onClose;
  final String closeLabel;
  final List<Widget> actions;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  State<GwTopBar> createState() => _GwTopBarState();
}

class _GwTopBarState extends State<GwTopBar> {
  ScrollNotificationObserverState? _observer;
  bool _under = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _observer?.removeListener(_onScroll);
    _observer = ScrollNotificationObserver.maybeOf(context)?..addListener(_onScroll);
  }

  @override
  void dispose() {
    _observer?.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll(ScrollNotification n) {
    if (n is! ScrollUpdateNotification || n.depth != 0 || n.metrics.axis != Axis.vertical) return;
    final under = n.metrics.extentBefore > 0;
    if (under != _under) setState(() => _under = under);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final change = MediaQuery.maybeDisableAnimationsOf(context) == true
        ? Duration.zero
        : const Duration(milliseconds: 320);
    final iconColor = c.ink;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: statusBarStyle(Theme.of(context).brightness),
      child: AnimatedContainer(
        duration: change,
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: c.card.withValues(alpha: _under ? 1 : 0),
          border: Border(
            bottom: BorderSide(color: c.line.withValues(alpha: _under ? 1 : 0)),
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: 56,
            child: Row(
              children: [
                if (widget.onClose == null && (ModalRoute.of(context)?.canPop ?? false))
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: IconButton(
                      tooltip: '뒤로',
                      icon: Icon(Icons.arrow_back_rounded, color: iconColor),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  )
                else
                  const SizedBox(width: 20),
                Expanded(
                  child: AnimatedOpacity(
                    opacity: _under && widget.title != null ? 1 : 0,
                    duration: change,
                    curve: Curves.easeOutCubic,
                    child: Text(
                      widget.title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.ink),
                    ),
                  ),
                ),
                ...widget.actions,
                if (widget.onClose case final close?)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: IconButton(
                      tooltip: widget.closeLabel,
                      icon: Icon(Icons.close_rounded, color: iconColor),
                      onPressed: close,
                    ),
                  )
                else
                  const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
