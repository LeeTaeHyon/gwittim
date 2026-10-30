import 'package:flutter/material.dart';

import '../data/models.dart';
import 'briefing_data.dart';
import 'components.dart';
import 'format.dart';
import 'theme.dart';

typedef OpenNotice = Future<void> Function(NoticeSummary notice, Recommendation? recommendation);

/// 학과 통계 추천에 답한다. 학과 통계 추천을 그만 보이게 됐으면 true (D-021).
typedef AnswerMajorPick = Future<bool> Function(RecommendationEntry entry, bool interested);

/// 귀띔 브리핑 (D-009, D-018). 하루 첫 실행 때 전체 화면으로 보이고, 홈의 '오늘의 귀띔'에서 다시 연다.
/// 조건에 맞는 공고가 있는 소식만 보인다. 문장은 템플릿이다 (사용자별 LLM 생성 아님).
/// 머리는 브랜드 면(네이비 + 라임), 소식 카드는 흰 바탕.
class BriefingScreen extends StatelessWidget {
  const BriefingScreen({
    super.key,
    required this.briefing,
    required this.today,
    required this.onOpenNotice,
    this.onAnswerMajorPick,
  });

  final Briefing briefing;
  final DateTime today;
  final OpenNotice onOpenNotice;
  final AnswerMajorPick? onAnswerMajorPick;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final sections = <Widget>[
      if (briefing.savedSoon.isNotEmpty)
        _SavedSoonBubble(
          entries: briefing.savedSoon,
          today: today,
          onOpen: () => _open(context, briefing.savedSoon.first.notice, null),
        ),
      if (briefing.urgent case final u?)
        _UrgentBubble(entry: u, today: today, onOpen: () => _open(context, u.notice, u.recommendation)),
      if (briefing.majorPick case final m?)
        _MajorPickBubble(
          entry: m,
          today: today,
          onOpen: () => _open(context, m.notice, m.recommendation),
          onAnswer: onAnswerMajorPick,
        ),
      if (briefing.fresh.isNotEmpty)
        _ListBubble(
          kicker: '새 공고',
          title: '최근 3일 안에 올라온\n맞춤 공고 ',
          entries: briefing.fresh,
          today: today,
          onOpen: (e) => _open(context, e.notice, e.recommendation),
        ),
      if (briefing.career.isNotEmpty)
        _ListBubble(
          kicker: '진로 관련 기회',
          title: '관심 분야 밖이지만\n희망 직무와 관련된 공고 ',
          entries: briefing.career,
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
              child: _Hero(briefing: briefing, today: today),
            ),
            const SizedBox(height: 14),
            for (var i = 0; i < sections.length; i++) ...[
              _Rise(delay: 300 + i * 250, child: sections[i]),
              const SizedBox(height: 14),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: Text(
                '추천 순서는 관심사·희망 직무·전공·학과 통계·마감 시기로 정해요. 합격 가능성을 뜻하지 않아요.',
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
    final due = n.applicationDeadline!.day;
    final reason = entry.recommendation.reasonCodes.where(personalReasons.containsKey).firstOrNull;
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
          Text(
            '${due.month}월 ${due.day}일 마감 · ${left == 0 ? '오늘' : 'D-$left'}',
            style: _title(c).copyWith(color: c.urgent),
          ),
          // 마감이 가까워서가 아니라 관련이 있어서 보여 준다는 것을 밝힌다.
          if (reason != null) ...[
            const SizedBox(height: 6),
            Text(reasonText(reason), style: TextStyle(fontSize: 14, height: 1.5, color: c.sub)),
          ],
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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(Icons.help_outline_rounded, size: 18, color: c.check),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '지원 자격 일부 확인 필요',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.body),
                      ),
                      for (final r in checkReasons(entry.recommendation))
                        Text(r, style: TextStyle(fontSize: 13.5, height: 1.5, color: c.sub)),
                    ],
                  ),
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

/// 학과 통계로만 고른 공고를 고른 분야와 구분해 보이는 표시 (D-021)
class MajorPickLabel extends StatelessWidget {
  const MajorPickLabel({super.key});

  @override
  Widget build(BuildContext context) => const Pill('학과 통계 추천', tone: PillTone.neutral);
}

/// 학과 통계 추천 (D-021). 학생이 고르지 않은 분야를 앱이 먼저 권하는 것이라, 표시를 붙이고 원하는지 묻는다.
class _MajorPickBubble extends StatefulWidget {
  const _MajorPickBubble({required this.entry, required this.today, required this.onOpen, this.onAnswer});

  final RecommendationEntry entry;
  final DateTime today;
  final VoidCallback onOpen;
  final AnswerMajorPick? onAnswer;

  @override
  State<_MajorPickBubble> createState() => _MajorPickBubbleState();
}

class _MajorPickBubbleState extends State<_MajorPickBubble> {
  /// 답한 뒤 보일 문장
  String? _answered;

  Future<void> _answer(bool interested) async {
    final stopped = await widget.onAnswer!(widget.entry, interested);
    if (!mounted) return;
    setState(
      () => _answered = interested
          ? '알려 주셔서 고마워요. 학과 통계 추천을 계속 보여 드릴게요.'
          : stopped
          ? '관심 없다는 답이 이어져서 학과 통계 추천을 $majorPickPauseDays일 동안 쉬어요.'
          : '이 공고는 다시 권하지 않을게요.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final n = widget.entry.notice;
    final left = daysLeft(n, widget.today)!;
    final due = n.applicationDeadline!.day;
    return GwCard(
      bubble: true,
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const MajorPickLabel(),
          const SizedBox(height: 10),
          Text(n.title, style: _title(c), maxLines: 3, overflow: TextOverflow.ellipsis),
          Text(
            '${due.month}월 ${due.day}일 마감 · ${left == 0 ? '오늘' : 'D-$left'}',
            style: _title(c).copyWith(color: c.urgent),
          ),
          const SizedBox(height: 6),
          Text(
            '직접 고른 분야가 아니라, 같은 학과 졸업생이 많이 가는 분야라서 권해 드려요.',
            style: TextStyle(fontSize: 14, height: 1.5, color: c.sub),
          ),
          const SizedBox(height: 4),
          Text('커리어넷 학과정보 통계(2020 조사)로 골랐어요.', style: captionStyle(context)),
          const SizedBox(height: 16),
          SoftButton(label: '공고 보기', onPressed: widget.onOpen),
          if (widget.onAnswer != null) ...[
            const SizedBox(height: 16),
            Divider(height: 1, thickness: 1, color: c.line),
            const SizedBox(height: 14),
            if (_answered case final text?)
              Text(text, style: TextStyle(fontSize: 14, height: 1.5, color: c.sub))
            else ...[
              Text(
                '이런 추천을 계속 받아 볼까요?',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.body),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  SoftButton(label: '관심 있어요', icon: null, onPressed: () => _answer(true)),
                  SoftButton(label: '관심 없어요', icon: null, onPressed: () => _answer(false)),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// 브리핑 머리: 네이비 면 위에 귀띔 배지·날짜, 흰 제목('주요 소식'은 라임 면), 소식마다 반투명 배지.
class _Hero extends StatelessWidget {
  const _Hero({required this.briefing, required this.today});

  final Briefing briefing;
  final DateTime today;

  /// 네이비 위 소식 배지 바탕 (흰색 12%)
  static const _tagFill = Color(0x1FFFFFFF);

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final headline = TextStyle(fontSize: 26, height: 1.4, fontWeight: FontWeight.w700, color: c.loginInk);
    final b = briefing;
    final tags = [
      if (b.savedSoon.isNotEmpty) '저장 공고 곧 마감 ${b.savedSoon.length}건',
      if (b.urgent != null) '마감 임박',
      if (b.fresh.isNotEmpty) '새 공고 ${b.fresh.length}건',
      if (b.career.isNotEmpty) '진로 관련 ${b.career.length}건',
      if (b.majorPick != null) '학과 통계 추천',
      if (b.changed.isNotEmpty) '마감 변경 ${b.changed.length}건',
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
      decoration: BoxDecoration(color: c.hero, borderRadius: Gw.bubble),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const GwBadge(),
              const SizedBox(width: 8),
              Text(
                '${today.month}월 ${today.day}일 ${weekdayName(today)}요일',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.loginSub),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // 소식 종류 수는 공고 수로 오해되기 쉬워 세지 않는다.
          Text.rich(
            TextSpan(
              style: headline,
              children: [
                const TextSpan(text: '오늘의 '),
                WidgetSpan(
                  alignment: PlaceholderAlignment.baseline,
                  baseline: TextBaseline.alphabetic,
                  // 라임 면 위 짙은 글자: 투명한 형광펜은 네이비 위에서 탁해져서 면으로 칠한다.
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(color: c.lime, borderRadius: BorderRadius.circular(8)),
                    child: Text('주요 소식', style: headline.copyWith(color: c.limeInk)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in tags)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: _tagFill, borderRadius: BorderRadius.circular(12)),
                  child: Text(
                    t,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.loginInk),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 저장한 공고 마감이 이틀 안에 오면 맨 위에 둔다.
class _SavedSoonBubble extends StatelessWidget {
  const _SavedSoonBubble({required this.entries, required this.today, required this.onOpen});

  final List<SavedEntry> entries;
  final DateTime today;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final n = entries.first.notice;
    final left = daysLeft(n, today)!;
    final deadline = n.applicationDeadline!;
    return GwCard(
      bubble: true,
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('저장한 공고', style: _kicker(c)),
          const SizedBox(height: 6),
          Text(n.title, style: _title(c), maxLines: 3, overflow: TextOverflow.ellipsis),
          Text(left == 0 ? '오늘 신청이 마감돼요' : '신청 마감이 $left일 남았어요', style: _title(c).copyWith(color: c.urgent)),
          const SizedBox(height: 6),
          Text(
            '${deadline.day.month}월 ${deadline.day.day}일${deadline.hasTime ? ' ${deadline.time}' : ''} 마감',
            style: TextStyle(fontSize: 14, color: c.sub),
          ),
          if (entries.length > 1) ...[
            const SizedBox(height: 4),
            Text('저장한 공고 ${entries.length - 1}건도 이틀 안에 마감돼요', style: captionStyle(context)),
          ],
          const SizedBox(height: 16),
          SoftButton(label: '공고 보기', onPressed: onOpen),
        ],
      ),
    );
  }
}

/// 공고 몇 건을 묶어 보이는 소식 (새 공고, 진로 관련 기회). 3건까지 보이고 나머지는 개수만.
class _ListBubble extends StatelessWidget {
  const _ListBubble({
    required this.kicker,
    required this.title,
    required this.entries,
    required this.today,
    required this.onOpen,
  });

  final String kicker;

  /// 끝에 건수가 형광펜으로 붙는다.
  final String title;
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
          Text(kicker, style: _kicker(c)),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              style: _title(c),
              children: [
                TextSpan(text: title),
                markSpan('${entries.length}건', _title(c)),
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
              child: Text('외 ${entries.length - 3}건은 공고 탭에서 볼 수 있어요', style: captionStyle(context)),
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
