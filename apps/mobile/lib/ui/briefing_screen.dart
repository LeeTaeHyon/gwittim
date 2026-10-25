import 'package:flutter/material.dart';

import '../data/models.dart';
import 'briefing_data.dart';
import 'components.dart';
import 'format.dart';
import 'theme.dart';

typedef OpenNotice = Future<void> Function(NoticeSummary notice, Recommendation? recommendation);

/// 귀띔 브리핑 (D-009). 하루 첫 실행 때 전체 화면으로 보이고, 홈의 '오늘의 귀띔'에서 다시 연다.
/// 문장은 템플릿이다 (사용자별 LLM 생성 아님).
class BriefingScreen extends StatelessWidget {
  const BriefingScreen({super.key, required this.briefing, required this.today, required this.onOpenNotice});

  final Briefing briefing;
  final DateTime today;
  final OpenNotice onOpenNotice;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final headline = TextStyle(fontSize: 28, height: 1.42, fontWeight: FontWeight.w700, color: c.ink);
    final sections = <Widget>[
      if (briefing.urgent case final u?)
        _UrgentBubble(entry: u, today: today, onOpen: () => _open(context, u.notice, u.recommendation)),
      if (briefing.related.isNotEmpty)
        _RelatedBubble(
          entries: briefing.related,
          today: today,
          onOpen: (e) => _open(context, e.notice, e.recommendation),
        ),
      if (briefing.changed.isNotEmpty) _ChangedBubble(entry: briefing.changed.first, more: briefing.changed.length - 1),
    ];
    // 아래 버튼 뒤로 목록이 이어지고, 버튼 위 24는 바탕색으로 흐려진다. 마지막 항목 아래에는 버튼 높이만큼 비운다.
    return Scaffold(
      extendBody: true,
      appBar: GwTopBar(onClose: () => Navigator.of(context).pop(), closeLabel: '브리핑 닫기'),
      // 여백은 Scaffold가 아래 버튼 높이를 더한 MediaQuery에서 읽는다.
      body: Builder(
        builder: (context) => ListView(
          padding: EdgeInsets.fromLTRB(16, 0, 16, MediaQuery.paddingOf(context).bottom + 8),
          children: [
            _Rise(
              delay: 0,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const GwBadge(),
                        const SizedBox(width: 8),
                        Text(
                          '${today.month}월 ${today.day}일 ${weekdayName(today)}요일',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.muted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text('오늘 챙길 소식이', style: headline),
                    Text.rich(
                      TextSpan(
                        style: headline,
                        children: [
                          WidgetSpan(
                            alignment: PlaceholderAlignment.baseline,
                            baseline: TextBaseline.alphabetic,
                            child: Marker(
                              '${briefing.count}가지',
                              style: headline,
                              animate: true,
                              delay: const Duration(milliseconds: 450),
                            ),
                          ),
                          const TextSpan(text: ' 있어요'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            for (var i = 0; i < sections.length; i++) ...[
              _Rise(delay: 300 + i * 250, child: sections[i]),
              const SizedBox(height: 14),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: Text(
                '추천 순서는 관심사·희망 직무·전공·마감 시기로 정해요. 합격 가능성을 뜻하지 않아요.',
                style: TextStyle(fontSize: 12.5, height: 1.6, color: c.muted),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IgnorePointer(
            child: Container(
              height: 24,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [c.bg.withValues(alpha: 0), c.bg],
                ),
              ),
            ),
          ),
          ColoredBox(
            color: c.bg,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('확인했어요')),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _open(BuildContext context, NoticeSummary notice, Recommendation? r) async {
    Navigator.of(context).pop();
    await onOpenNotice(notice, r);
  }
}

/// 섹션이 차례로 올라온다. 애니메이션 줄이기 설정이면 바로 보인다.
class _Rise extends StatelessWidget {
  const _Rise({required this.delay, required this.child});

  final int delay;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) return child;
    final total = delay + 600;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: Curves.easeOutCubic),
      builder: (_, t, c) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 16 * (1 - t)), child: c),
      ),
      child: child,
    );
  }
}

TextStyle _kicker(GwColors c) => TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.accent);
TextStyle _title(GwColors c) => TextStyle(fontSize: 21, height: 1.45, fontWeight: FontWeight.w700, color: c.ink);

class _UrgentBubble extends StatelessWidget {
  const _UrgentBubble({required this.entry, required this.today, required this.onOpen});

  final RecommendationEntry entry;
  final DateTime today;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final n = entry.notice;
    final left = daysLeft(n, today)!;
    final start = DateTime(today.year, today.month, today.day);
    final days = [for (var i = 0; i < 7; i++) start.add(Duration(days: i))];
    final c = context.gw;
    return GwCard(
      bubble: true,
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('마감 임박', style: _kicker(c).copyWith(color: c.urgent)),
          const SizedBox(height: 6),
          Text(n.title, style: _title(c), maxLines: 3, overflow: TextOverflow.ellipsis),
          Text(left == 0 ? '오늘 마감돼요' : '$left일 뒤 마감돼요', style: _title(c).copyWith(color: c.urgent)),
          const SizedBox(height: 18),
          // 오늘부터 7일: 오늘(라이트 네이비, 다크 라임)과 마감일(빨강)을 표시한다.
          Row(
            children: [
              for (final d in days)
                Expanded(
                  child: Column(
                    children: [
                      Text(weekdayName(d), style: TextStyle(fontSize: 12, color: c.muted)),
                      const SizedBox(height: 6),
                      Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: d == start ? c.point : (d.difference(start).inDays == left ? c.urgentFill : null),
                        ),
                        child: Text(
                          '${d.day}',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: d == start
                                ? c.onPoint
                                : (d.difference(start).inDays == left ? c.onUrgentFill : c.muted),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        d == start ? '오늘' : (d.difference(start).inDays == left ? '마감' : ''),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: d == start ? c.accent : c.urgent,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (entry.recommendation.eligibilityStatus == 'needs_check') ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.help_outline_rounded, size: 18, color: c.check),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('지원 조건 중 직접 확인할 것이 있어요', style: TextStyle(fontSize: 14, color: c.sub)),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          SoftButton(label: '공고 보기', onPressed: onOpen),
        ],
      ),
    );
  }
}

class _RelatedBubble extends StatelessWidget {
  const _RelatedBubble({required this.entries, required this.today, required this.onOpen});

  final List<RecommendationEntry> entries;
  final DateTime today;
  final void Function(RecommendationEntry) onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return GwCard(
      bubble: true,
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('맞춤 공고', style: _kicker(c)),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              style: _title(c),
              children: [
                const TextSpan(text: '관심 분야·직무·전공과\n관련된 공고가 '),
                markSpan('${entries.length}개', _title(c)),
                const TextSpan(text: ' 있어요'),
              ],
            ),
          ),
          const SizedBox(height: 14),
          for (final e in entries.take(3))
            InkWell(
              onTap: () => onOpen(e),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Container(
                      constraints: const BoxConstraints(minWidth: 52),
                      height: 26,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: c.chip, borderRadius: BorderRadius.circular(13)),
                      child: Text(switch (daysLeft(e.notice, today)) {
                        null => e.notice.deadlineNote == null ? '마감 미상' : '선착순',
                        0 => '오늘',
                        final d => 'D-$d',
                      }, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c.onChip)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        e.notice.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.body),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (entries.length > 3)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('외 ${entries.length - 3}개는 홈에서 볼 수 있어요', style: captionStyle(context)),
            ),
        ],
      ),
    );
  }
}

class _ChangedBubble extends StatelessWidget {
  const _ChangedBubble({required this.entry, required this.more});

  final SavedEntry entry;
  final int more;

  @override
  Widget build(BuildContext context) {
    final before = entry.saved.savedDeadlineSnapshot;
    final now = entry.notice.applicationDeadline;
    final c = context.gw;
    return GwCard(
      bubble: true,
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('저장한 공고', style: _kicker(c)),
          const SizedBox(height: 6),
          Text('${entry.notice.title}\n${deadlineChangeText(entry)}', style: _title(c)),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (before != null)
                Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(color: c.neutral, borderRadius: BorderRadius.circular(16)),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      shortDate(before),
                      style: TextStyle(fontSize: 14, color: c.muted, decoration: TextDecoration.lineThrough),
                    ),
                  ),
                ),
              if (before != null && now != null) Icon(Icons.arrow_forward_rounded, size: 18, color: c.faint),
              if (now != null)
                Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(color: c.point, borderRadius: BorderRadius.circular(16)),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      shortDate(now),
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.onPoint),
                    ),
                  ),
                ),
            ],
          ),
          if (more > 0) ...[
            const SizedBox(height: 10),
            Text('다른 저장 공고 $more개도 마감이 바뀌었어요', style: captionStyle(context)),
          ],
        ],
      ),
    );
  }
}
