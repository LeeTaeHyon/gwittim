import 'package:flutter/material.dart';

import '../data/cached_repository.dart';
import '../data/models.dart';
import '../data/repository.dart';
import 'briefing_data.dart';
import 'common.dart';
import 'components.dart';
import 'format.dart';
import 'icons.dart';
import 'report_screen.dart';
import 'skeleton.dart';
import 'theme.dart';

/// 달력에 놓는 공고 하나. 맞춤 공고와 저장한 공고에 다 있으면 하나로 합친다.
class CalendarItem {
  const CalendarItem({required this.notice, this.recommendation, required this.saved});

  final NoticeSummary notice;

  /// 추천 목록에서 왔으면 그 판정 (리포트에 넘긴다)
  final Recommendation? recommendation;
  final bool saved;
}

/// 확정 마감일별 공고 (D-017). 맞춤 공고는 다가오는 마감과 같은 기준(D-016)으로 고르고,
/// 저장한 공고는 관련 여부와 상관없이 넣는다. 마감일이 없는 공고(선착순 등)와 삭제된 공고는 넣지 않는다.
/// 날짜 안에서는 시각이 확인된 것을 먼저, 그다음 제목 순.
Map<DateTime, List<CalendarItem>> calendarItems(RecommendationList list, List<SavedEntry> saved) {
  final byId = <String, CalendarItem>{};
  for (final e in deadlineCandidates(list)) {
    if (e.notice.applicationDeadline == null) continue;
    byId[e.notice.noticeId] = CalendarItem(notice: e.notice, recommendation: e.recommendation, saved: false);
  }
  for (final s in saved) {
    final n = s.notice;
    if (n.applicationDeadline == null || n.lifecycleStatus == 'removed') continue;
    byId[n.noticeId] = CalendarItem(notice: n, recommendation: byId[n.noticeId]?.recommendation, saved: true);
  }
  final out = <DateTime, List<CalendarItem>>{};
  for (final item in byId.values) {
    (out[item.notice.applicationDeadline!.day] ??= []).add(item);
  }
  for (final items in out.values) {
    items.sort((a, b) {
      final ta = a.notice.applicationDeadline!.time;
      final tb = b.notice.applicationDeadline!.time;
      if ((ta == null) != (tb == null)) return ta == null ? 1 : -1;
      if (ta != null && tb != null && ta != tb) return ta.compareTo(tb);
      return a.notice.title.compareTo(b.notice.title);
    });
  }
  return out;
}

/// 달력 탭 (D-017). 월 달력에서 날짜를 고르면 그날 마감되는 공고가 아래에 보인다.
/// 기기 캘린더 연동·개인 시간표는 하지 않는다 (SPEC P0 제외).
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key, required this.repository, required this.openUrl, this.today});

  final NoticeRepository repository;
  final OpenUrl openUrl;

  /// 테스트용. 기본은 기기 날짜.
  final DateTime? today;

  @override
  State<CalendarScreen> createState() => CalendarScreenState();
}

const _weekdaysSunFirst = ['일', '월', '화', '수', '목', '금', '토'];

class CalendarScreenState extends State<CalendarScreen> {
  Map<DateTime, List<CalendarItem>>? _items;
  Map<String, String> _categories = const {};
  int _undated = 0;
  Object? _error;

  late DateTime _month = DateTime(_today.year, _today.month);
  late DateTime _selected = _day(_today);

  DateTime get _today => widget.today ?? DateTime.now();

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// 당겨서 새로 고침: 탭끼리 나눠 쓰는 응답도 버리고 서버에서 다시 받는다.
  Future<void> refresh() {
    forgetCached(widget.repository);
    return reload();
  }

  /// 탭을 다시 열거나 당겨서 새로고침할 때. 받는 동안 보이는 달력은 그대로 둔다.
  Future<void> reload() async {
    try {
      final list = await widget.repository.listRecommendations();
      List<SavedEntry> saved = const [];
      try {
        saved = await widget.repository.listSaved();
      } catch (_) {
        // 저장 목록을 못 읽어도 맞춤 공고는 보여준다.
      }
      var categories = _categories;
      try {
        categories = await widget.repository.categoryNames();
      } catch (_) {
        // 분류 이름만 코드로 보인다.
      }
      if (!mounted) return;
      final savedIds = {for (final s in saved) s.notice.noticeId};
      setState(() {
        _items = calendarItems(list, saved);
        _undated = deadlineCandidates(list)
            .where((e) => e.notice.applicationDeadline == null && !savedIds.contains(e.notice.noticeId))
            .length;
        _categories = categories;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (_items != null) {
        showRefreshFailed(context, e); // 보이던 달력은 그대로 둔다
      } else {
        setState(() => _error = e);
      }
    }
  }

  /// 달을 옮기면 이번 달은 오늘, 다른 달은 그 달 첫 마감일(없으면 1일)을 고른다.
  void _moveMonth(int delta) {
    final month = DateTime(_month.year, _month.month + delta);
    final today = _day(_today);
    final days =
        (_items?.keys ?? const <DateTime>[]).where((d) => d.year == month.year && d.month == month.month).toList()
          ..sort();
    setState(() {
      _month = month;
      _selected = month.year == today.year && month.month == today.month ? today : (days.firstOrNull ?? month);
    });
  }

  Future<void> _open(CalendarItem item) async {
    await Navigator.of(context).push(
      gwRoute(
        context,
        (_) => ReportScreen(
          repository: widget.repository,
          noticeId: item.notice.noticeId,
          openUrl: widget.openUrl,
          today: widget.today,
          recommendation: item.recommendation,
        ),
      ),
    );
    reload();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items == null) {
      if (_error != null) {
        return MessageView.error(
          _error!,
          onRetry: () {
            setState(() => _error = null);
            reload();
          },
        );
      }
      return const ListSkeleton(header: true);
    }
    final c = context.gw;
    final inMonth = items.entries
        .where((e) => e.key.year == _month.year && e.key.month == _month.month)
        .fold(0, (n, e) => n + e.value.length);
    final day = items[_selected] ?? const <CalendarItem>[];
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ScreenHeader('달력', trailing: '${_month.month}월 마감 $inMonth건'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GwCard(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _MonthBar(
                    month: _month,
                    isThisMonth: _month.year == _today.year && _month.month == _today.month,
                    onPrev: () => _moveMonth(-1),
                    onNext: () => _moveMonth(1),
                    onToday: () => _moveMonth((_today.year - _month.year) * 12 + _today.month - _month.month),
                  ),
                  const SizedBox(height: 4),
                  // 옆으로 밀어 달을 넘긴다.
                  GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragEnd: (d) {
                      final v = d.primaryVelocity ?? 0;
                      if (v.abs() > 300) _moveMonth(v < 0 ? 1 : -1);
                    },
                    child: _MonthGrid(
                      month: _month,
                      today: _day(_today),
                      selected: _selected,
                      items: items,
                      onSelect: (d) => setState(() => _selected = d),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const _Legend(),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SectionTitle(
              '${_selected.month}월 ${_selected.day}일(${weekdayName(_selected)}) 마감',
              trailing: Text(day.isEmpty ? '' : '${day.length}건', style: captionStyle(context)),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GwCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (day.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Text('이 날 마감되는 공고가 없습니다.', style: TextStyle(fontSize: 15, color: c.sub)),
                    ),
                  for (final item in day)
                    _DayRow(
                      item: item,
                      category: _categories[item.notice.category] ?? item.notice.category,
                      today: _today,
                      onTap: () => _open(item),
                    ),
                ],
              ),
            ),
          ),
          if (_undated > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: Text(
                '마감일이 정해지지 않은 공고 $_undated개(선착순 등)는 달력에 넣지 않았습니다.',
                style: TextStyle(fontSize: 13, height: 1.5, color: c.muted),
              ),
            ),
        ],
      ),
    );
  }
}

class _MonthBar extends StatelessWidget {
  const _MonthBar({
    required this.month,
    required this.isThisMonth,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
  });

  final DateTime month;
  final bool isThisMonth;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    // 달 이름은 카드 가운데에 두고, '오늘' 버튼은 오른쪽 끝에 겹쳐 둔다(나타나도 달 이름이 움직이지 않음).
    return Stack(
      alignment: Alignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: '이전 달',
              onPressed: onPrev,
              icon: Icon(Icons.chevron_left_rounded, color: c.ink),
            ),
            SizedBox(
              width: 128,
              child: Semantics(
                liveRegion: true,
                child: Text(
                  '${month.year}년 ${month.month}월',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.ink),
                ),
              ),
            ),
            IconButton(
              tooltip: '다음 달',
              onPressed: onNext,
              icon: Icon(Icons.chevron_right_rounded, color: c.ink),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Visibility(
            visible: !isThisMonth,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: TextButton(onPressed: onToday, child: const Text('오늘')),
          ),
        ),
      ],
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.today,
    required this.selected,
    required this.items,
    required this.onSelect,
  });

  final DateTime month;
  final DateTime today;
  final DateTime selected;
  final Map<DateTime, List<CalendarItem>> items;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final lead = DateTime(month.year, month.month).weekday % 7; // 일요일 시작
    final days = DateTime(month.year, month.month + 1, 0).day;
    final weeks = ((lead + days) / 7).ceil();
    return Column(
      children: [
        Row(
          children: [
            for (final w in _weekdaysSunFirst)
              Expanded(
                child: ExcludeSemantics(
                  child: Text(
                    w,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: c.muted),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        for (var w = 0; w < weeks; w++)
          Row(
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: switch (w * 7 + i - lead + 1) {
                    final d when d >= 1 && d <= days => _DayCell(
                      day: DateTime(month.year, month.month, d),
                      today: today,
                      selected: selected,
                      items: items[DateTime(month.year, month.month, d)] ?? const [],
                      onSelect: onSelect,
                    ),
                    _ => const SizedBox(height: _cellHeight),
                  },
                ),
            ],
          ),
      ],
    );
  }
}

const _cellHeight = 52.0;

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.today,
    required this.selected,
    required this.items,
    required this.onSelect,
  });

  final DateTime day;
  final DateTime today;
  final DateTime selected;
  final List<CalendarItem> items;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final isSelected = day == selected;
    final isToday = day == today;
    final past = day.isBefore(today);
    final hasSaved = items.any((i) => i.saved);
    final hasOther = items.any((i) => !i.saved);
    return Semantics(
      button: true,
      selected: isSelected,
      label:
          '${day.month}월 ${day.day}일 ${weekdayName(day)}요일${isToday ? ', 오늘' : ''}'
          '${items.isEmpty ? '' : ', 마감 ${items.length}건'}',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('day-${day.month}-${day.day}'),
        onTap: () => onSelect(day),
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: _cellHeight,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 고른 날은 point 면, 오늘은 테두리만
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isSelected ? c.point : null,
                  border: isToday && !isSelected ? Border.all(color: c.accent, width: 1.5) : null,
                ),
                child: Text(
                  '${day.day}',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: isSelected || isToday ? FontWeight.w700 : FontWeight.w500,
                    color: isSelected ? c.onPoint : (isToday ? c.accent : (past ? c.muted : c.body)),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 6,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  spacing: 3,
                  children: [if (hasSaved) const _Dot(saved: true), if (hasOther) const _Dot(saved: false)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 저장한 공고는 채운 점(point), 맞춤 공고는 테두리 점(accent). 색이 비슷해도 모양으로 구분된다.
class _Dot extends StatelessWidget {
  const _Dot({required this.saved});

  final bool saved;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Container(
      key: ValueKey(saved ? 'dot-saved' : 'dot-related'),
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: saved ? c.point : null,
        border: saved ? null : Border.all(color: c.accent, width: 1.5),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 12.5, color: context.gw.muted);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const _Dot(saved: true),
        const SizedBox(width: 6),
        Text('저장한 공고', style: style),
        const SizedBox(width: 16),
        const _Dot(saved: false),
        const SizedBox(width: 6),
        Text('맞춤 공고', style: style),
      ],
    );
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow({required this.item, required this.category, required this.today, required this.onTap});

  final CalendarItem item;
  final String category;
  final DateTime today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final n = item.notice;
    final deadline = n.applicationDeadline!;
    final c = context.gw;
    final label = daysLeftLabel(n, today);
    final urgent = (daysLeft(n, today) ?? 99) <= urgentDays;
    final status = item.recommendation?.eligibilityStatus;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    n.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.body, height: 1.4),
                  ),
                  const SizedBox(height: 2),
                  // 남은 날과 시각을 앞에 굵게, 분류와 상태는 뒤에 흐리게 (ui-style §7 메타 줄)
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: [
                            label ?? '마감', // 지났거나 모집이 끝난 공고
                            if (deadline.hasTime) '${deadline.time} 마감',
                          ].join(' · '),
                          style: TextStyle(fontWeight: FontWeight.w600, color: urgent ? c.urgent : c.sub),
                        ),
                        TextSpan(text: ' · $category'),
                        if (status != null && status != 'met') TextSpan(text: ' · ${eligibilityShort(status)}'),
                      ],
                    ),
                    style: TextStyle(fontSize: 13, color: c.muted),
                  ),
                ],
              ),
            ),
            if (item.saved)
              Padding(
                padding: const EdgeInsets.only(left: 10, top: 2),
                child: GwIcon(GwGlyph.saved, filled: true, size: 20, color: c.point, semanticLabel: '저장한 공고'),
              ),
          ],
        ),
      ),
    );
  }
}
