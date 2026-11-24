import 'package:flutter/material.dart';

import 'briefing_data.dart';
import 'format.dart';
import 'theme.dart';

/// 브리핑 머리·도착 장면이 쓰는 조각 (hero 면 위).

/// '11월 19일 수요일'
String briefingDay(DateTime d) => '${d.month}월 ${d.day}일 ${weekdayName(d)}요일';

/// 라임 면 위 짙은 글자. [animate]면 왼쪽에서 오른쪽으로 700ms 칠해진다(지연 [delay], 애니메이션 줄이기면 칠한 상태).
/// [started]가 false인 동안은 칠하기 전 모습으로 기다린다. 네이비 위에 투명한 형광펜은 탁해져서 면으로 칠한다.
class LimeFace extends StatelessWidget {
  const LimeFace(
    this.text, {
    super.key,
    required this.style,
    this.animate = false,
    this.started = true,
    this.delay = Duration.zero,
  });

  final String text;

  /// 칠한 뒤의 글자 스타일 (색은 [GwColors.limeInk]로 정해진다)
  final TextStyle style;
  final bool animate;
  final bool started;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    Widget face(double t) => CustomPaint(
      painter: _FacePainter(c.lime, t),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(text, style: style.copyWith(color: Color.lerp(c.loginInk, c.limeInk, t))),
      ),
    );
    if (!animate || MediaQuery.maybeDisableAnimationsOf(context) == true) return face(1);
    if (!started) return face(0);
    final total = 700 + delay.inMilliseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay.inMilliseconds / total, 1, curve: Curves.easeOutCubic),
      builder: (_, t, _) => face(t),
    );
  }
}

class _FacePainter extends CustomPainter {
  _FacePainter(this.color, this.progress);

  final Color color;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width * progress, size.height));
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_FacePainter old) => old.progress != progress || old.color != color;
}

/// 숫자 줄: 우선순위대로 0건이 아닌 것만 최대 3개를 '아이콘 이름 숫자'로 한 줄에 둔다(상자 없음).
/// 줄이 모자라면 항목 단위로 아랫줄로 넘어간다. 하나도 없으면 아무것도 두지 않는다.
class BriefingStatRow extends StatelessWidget {
  const BriefingStatRow({super.key, required this.briefing});

  final Briefing briefing;

  @override
  Widget build(BuildContext context) {
    final stats = briefingStats(briefing);
    if (stats.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 16,
      runSpacing: 6,
      children: [for (final s in stats) _StatItem(kind: s.kind, count: s.count)],
    );
  }
}

(IconData, String) _look(BriefingStatKind kind) => switch (kind) {
  BriefingStatKind.urgent => (Icons.alarm_rounded, '마감 임박'),
  BriefingStatKind.savedSoon => (Icons.bookmark_rounded, '저장 곧 마감'),
  BriefingStatKind.fresh => (Icons.fiber_new_rounded, '새 공고'),
  BriefingStatKind.career => (Icons.explore_rounded, '진로 관련'),
  BriefingStatKind.changed => (Icons.update_rounded, '마감 변경'),
};

class _StatItem extends StatelessWidget {
  const _StatItem({required this.kind, required this.count});

  final BriefingStatKind kind;
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final (icon, name) = _look(kind);
    final accent = kind == BriefingStatKind.urgent ? c.heroUrgent : null;
    return Semantics(
      label: '$name $count건',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: accent ?? c.loginSub),
          const SizedBox(width: 5),
          Text(
            name,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.loginSub),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: accent ?? c.loginInk,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
