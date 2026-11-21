import 'package:flutter/material.dart';

import 'briefing_data.dart';
import 'format.dart';
import 'theme.dart';

/// 홈 '오늘의 귀띔' 카드와 브리핑 머리가 함께 쓰는 조각 (hero 면 위).

/// '11월 19일 수요일'
String briefingDay(DateTime d) => '${d.month}월 ${d.day}일 ${weekdayName(d)}요일';

/// hero 위 반투명 면과 테두리. loginInk는 두 테마 모두 흰색이다.
Color heroTileFill(GwColors c) => c.loginInk.withValues(alpha: 0.12);

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

/// 숫자 칸 줄: 우선순위대로 0건이 아닌 것만 최대 3칸, 가로 균등. 하나도 없으면 아무것도 두지 않는다.
class BriefingStatRow extends StatelessWidget {
  const BriefingStatRow({super.key, required this.briefing});

  final Briefing briefing;

  @override
  Widget build(BuildContext context) {
    final stats = briefingStats(briefing);
    if (stats.isEmpty) return const SizedBox.shrink();
    // 칸 이름이 두 줄로 넘어가도 세 칸 높이가 같도록 가장 높은 칸에 맞춘다.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < stats.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(child: _StatTile(kind: stats[i].kind, count: stats[i].count)),
          ],
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.kind, required this.count});

  final BriefingStatKind kind;
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final (icon, name) = switch (kind) {
      BriefingStatKind.urgent => (Icons.alarm_rounded, '마감 임박'),
      BriefingStatKind.savedSoon => (Icons.bookmark_rounded, '저장 곧 마감'),
      BriefingStatKind.fresh => (Icons.fiber_new_rounded, '새 공고'),
      BriefingStatKind.career => (Icons.explore_rounded, '진로 관련'),
      BriefingStatKind.changed => (Icons.update_rounded, '마감 변경'),
    };
    final accent = kind == BriefingStatKind.urgent ? c.heroUrgent : null;
    return Semantics(
      label: '$name $count건',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 10),
        decoration: BoxDecoration(color: heroTileFill(c), borderRadius: BorderRadius.circular(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: accent ?? c.loginSub),
            const SizedBox(height: 6),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 28,
                height: 1.1,
                fontWeight: FontWeight.w700,
                color: accent ?? c.loginInk,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              name,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.loginSub),
            ),
          ],
        ),
      ),
    );
  }
}
