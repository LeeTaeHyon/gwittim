import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repository.dart';
import 'briefing_data.dart';
import 'common.dart';
import 'components.dart';
import 'format.dart';
import 'report_screen.dart';
import 'theme.dart';

/// 저장한 공고 (D-010). 마감 기준으로 묶고, 최신 공고 상태와 저장 이후 바뀐 마감을 함께 보인다 (SPEC §6).
class SavedScreen extends StatefulWidget {
  const SavedScreen({super.key, required this.repository, required this.openUrl, this.today});

  final NoticeRepository repository;
  final OpenUrl openUrl;
  final DateTime? today;

  @override
  State<SavedScreen> createState() => SavedScreenState();
}

/// 마감일 오름차순. 확정 마감이 없는 공고(선착순·미상)는 뒤로, 그 안에서는 저장 최신순.
List<SavedEntry> sortByDeadline(List<SavedEntry> entries) {
  final list = [...entries];
  list.sort((a, b) {
    final da = a.notice.applicationDeadline?.date;
    final db = b.notice.applicationDeadline?.date;
    if (da != null && db != null && da != db) return da.compareTo(db);
    if ((da == null) != (db == null)) return da == null ? 1 : -1;
    return b.saved.savedAt.compareTo(a.saved.savedAt);
  });
  return list;
}

/// 마감 기준 묶음. 순서대로 보인다.
enum SavedGroup {
  thisWeek('이번 주 마감'),
  nextWeek('다음 주 마감'),
  later('그 이후'),
  noDeadline('마감일 없음'),
  past('지난 공고');

  const SavedGroup(this.title);

  final String title;
}

/// 마감된·삭제된 공고와 마감일이 지난 공고는 '지난 공고'. 주는 월요일에 시작한다.
SavedGroup savedGroupOf(SavedEntry e, DateTime today) {
  final n = e.notice;
  if (n.lifecycleStatus == 'closed' || n.lifecycleStatus == 'removed') return SavedGroup.past;
  final deadline = n.applicationDeadline;
  if (deadline == null) return SavedGroup.noDeadline;
  final day = DateTime(today.year, today.month, today.day);
  if (deadline.day.isBefore(day)) return SavedGroup.past;
  final weekStart = day.subtract(Duration(days: day.weekday - DateTime.monday));
  return switch (deadline.day.difference(weekStart).inDays ~/ 7) {
    0 => SavedGroup.thisWeek,
    1 => SavedGroup.nextWeek,
    _ => SavedGroup.later,
  };
}

/// 묶음별 목록. 빈 묶음은 넣지 않는다. 묶음 안은 마감일 순.
List<(SavedGroup, List<SavedEntry>)> groupSaved(List<SavedEntry> entries, DateTime today) {
  final sorted = sortByDeadline(entries);
  return [
    for (final g in SavedGroup.values)
      if (sorted.where((e) => savedGroupOf(e, today) == g).toList() case final list when list.isNotEmpty) (g, list),
  ];
}

/// 저장한 뒤 마감일이 바뀐 모집 중 공고 (브리핑과 같은 기준)
List<SavedEntry> deadlineChangedEntries(List<SavedEntry> entries) => [
  for (final e in sortByDeadline(entries))
    if (e.deadlineChanged && e.notice.lifecycleStatus == 'open') e,
];

class SavedScreenState extends State<SavedScreen> {
  List<SavedEntry>? _entries;
  Map<String, String> _categories = const {};
  Object? _error;

  /// 이 화면에서 저장을 끈 공고. 다시 켤 수 있게 다음 새로고침까지 목록에 남긴다.
  final Set<String> _unsaved = {};
  final Set<String> _busy = {};

  DateTime get _today => widget.today ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// 탭을 다시 열거나 당겨서 새로고침할 때. 받는 동안 보이는 목록은 그대로 둔다.
  Future<void> reload() async {
    try {
      final entries = await widget.repository.listSaved();
      var categories = _categories;
      try {
        categories = await widget.repository.categoryNames();
      } catch (_) {
        // 분류 이름만 코드로 보인다.
      }
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _categories = categories;
        _error = null;
        _unsaved.clear();
      });
    } catch (e) {
      if (!mounted) return;
      if (_entries != null) {
        showRefreshFailed(context, e); // 보이던 목록은 그대로 둔다
      } else {
        setState(() => _error = e);
      }
    }
  }

  void _say(ScaffoldMessengerState messenger, String text) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _toggle(SavedEntry e) async {
    final id = e.notice.noticeId;
    if (!_busy.add(id)) return;
    final messenger = ScaffoldMessenger.of(context);
    final wasSaved = !_unsaved.contains(id);
    setState(() => wasSaved ? _unsaved.add(id) : _unsaved.remove(id));
    try {
      if (wasSaved) {
        await widget.repository.deleteSaved(id);
      } else {
        await widget.repository.saveNotice(id);
      }
      _say(messenger, wasSaved ? '저장을 취소했어요.' : '저장했어요.');
    } catch (err) {
      if (mounted) setState(() => wasSaved ? _unsaved.remove(id) : _unsaved.add(id));
      _say(messenger, errorMessage(err));
    } finally {
      _busy.remove(id);
    }
  }

  /// 학교 공지에서 삭제된 공고를 저장 목록에서 지운다 (delete_saved_notice).
  Future<void> _dismiss(SavedEntry e) async {
    final id = e.notice.noticeId;
    if (!_busy.add(id)) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.repository.deleteSaved(id);
      if (mounted) setState(() => _entries = [...?_entries]..remove(e));
      _say(messenger, '목록에서 지웠어요.');
    } catch (err) {
      _say(messenger, errorMessage(err));
    } finally {
      _busy.remove(id);
    }
  }

  Future<void> _open(SavedEntry e) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReportScreen(
          repository: widget.repository,
          noticeId: e.notice.noticeId,
          openUrl: widget.openUrl,
          today: widget.today,
        ),
      ),
    );
    reload();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    if (entries == null) {
      if (_error != null) {
        return MessageView(
          icon: Icons.cloud_off,
          message: errorMessage(_error!),
          onRetry: () {
            setState(() => _error = null);
            reload();
          },
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    final c = context.gw;
    final changed = deadlineChangedEntries(entries);
    final count = entries.where((e) => !_unsaved.contains(e.notice.noticeId)).length;
    return RefreshIndicator(
      onRefresh: reload,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: ScreenHeader('저장한 공고', trailing: entries.isEmpty ? null : '$count개')),
          if (changed.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: TipBubble(
                  title: '마감일이 바뀐 공고가 ${changed.length}개 있어요',
                  detail: _changeDetail(changed),
                  onTap: () => _open(changed.first),
                ),
              ),
            ),
          SliverFillRemaining(
            hasScrollBody: false,
            child: Container(
              margin: const EdgeInsets.only(top: 16),
              padding: const EdgeInsets.fromLTRB(20, 26, 20, 32),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: entries.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.only(top: 40),
                      child: Text(
                        '저장한 공고가 없어요.\n공고 리포트에서 북마크를 누르면 여기에 모여요.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 15, height: 1.6, color: c.sub),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final (i, (group, list)) in groupSaved(entries, _today).indexed) ...[
                          Padding(
                            padding: EdgeInsets.only(top: i == 0 ? 0 : 18),
                            child: Semantics(
                              header: true,
                              child: Text(
                                group.title,
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c.muted),
                              ),
                            ),
                          ),
                          for (final e in list)
                            _SavedRow(
                              key: ValueKey(e.notice.noticeId),
                              entry: e,
                              group: group,
                              category: _categories[e.notice.category] ?? e.notice.category,
                              today: _today,
                              saved: !_unsaved.contains(e.notice.noticeId),
                              onTap: e.notice.lifecycleStatus == 'removed' ? null : () => _open(e),
                              onToggle: () => _toggle(e),
                              onDismiss: () => _dismiss(e),
                            ),
                        ],
                        const SizedBox(height: 20),
                        Text('마감일과 모집 상태는 학교 공지를 다시 확인할 때마다 최신으로 바뀌어요.', style: captionStyle(context)),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  String _changeDetail(List<SavedEntry> changed) {
    final first = changed.first;
    if (changed.length > 1) return '${first.notice.title} 외 ${changed.length - 1}개';
    final before = first.saved.savedDeadlineSnapshot;
    final now = first.notice.applicationDeadline;
    return '${first.notice.title} · ${before == null ? '마감일 없음' : shortDate(before)} → '
        '${now == null ? '마감일 없음' : shortDate(now)}';
  }
}

class _SavedRow extends StatelessWidget {
  const _SavedRow({
    super.key,
    required this.entry,
    required this.group,
    required this.category,
    required this.today,
    required this.saved,
    required this.onTap,
    required this.onToggle,
    required this.onDismiss,
  });

  final SavedEntry entry;
  final SavedGroup group;
  final String category;
  final DateTime today;
  final bool saved;
  final VoidCallback? onTap;
  final VoidCallback onToggle;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final n = entry.notice;
    final removed = n.lifecycleStatus == 'removed';
    final past = group == SavedGroup.past;
    final changed = entry.deadlineChanged && n.lifecycleStatus == 'open';
    final before = entry.saved.savedDeadlineSnapshot;
    final meta = TextStyle(fontSize: 13, height: 1.5, color: c.muted);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 34,
              child: _DateColumn(notice: n, group: group, today: today),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    n.title,
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.45,
                      fontWeight: FontWeight.w600,
                      color: past ? c.muted : c.body,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (removed)
                    Text(
                      '학교 공지에서 삭제됐어요',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.urgent),
                    )
                  else
                    Text(_metaLine(n), style: meta),
                  if (changed) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Pill('마감일 바뀜'),
                        Text(before == null ? '저장할 때는 마감일이 없었어요' : '저장할 때는 ${shortDate(before)}', style: meta),
                      ],
                    ),
                  ],
                  if (removed) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: onDismiss,
                      style: TextButton.styleFrom(
                        backgroundColor: c.neutral,
                        foregroundColor: c.sub,
                        minimumSize: const Size(0, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        shape: const StadiumBorder(),
                        textStyle: const TextStyle(fontFamily: 'Pretendard', fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      child: const Text('목록에서 지우기'),
                    ),
                  ],
                ],
              ),
            ),
            if (!removed)
              IconButton(
                tooltip: saved ? '저장 취소' : '저장',
                isSelected: saved,
                onPressed: onToggle,
                icon: Icon(Icons.bookmark_border, color: c.muted),
                selectedIcon: Icon(Icons.bookmark, color: c.point),
              ),
          ],
        ),
      ),
    );
  }

  /// 분류 · (확인된 시각) · D-day. 확정 마감이 없으면 원문 설명.
  String _metaLine(NoticeSummary n) {
    final deadline = n.applicationDeadline;
    final left = daysLeft(n, today);
    return [
      category,
      if (n.lifecycleStatus == 'closed')
        '모집이 끝났어요'
      else if (deadline == null)
        n.deadlineNote ?? '마감일이 공고에 나와 있지 않아요'
      else if (deadline.day.isBefore(DateTime(today.year, today.month, today.day)))
        '마감일이 지났어요'
      else ...[
        if (deadline.hasTime) '${deadline.time} 마감',
        if (left != null) left == 0 ? '오늘 마감' : 'D-$left',
      ],
      if (n.lifecycleStatus == 'unknown') '모집 상태 미확인',
    ].join(' · ');
  }
}

/// 왼쪽 마감 날짜. 이번 주·다음 주는 요일, 그 밖은 달을 함께 보인다.
class _DateColumn extends StatelessWidget {
  const _DateColumn({required this.notice, required this.group, required this.today});

  final NoticeSummary notice;
  final SavedGroup group;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    if (notice.lifecycleStatus == 'removed') {
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Icon(Icons.delete_outline, size: 20, color: c.faint),
      );
    }
    final deadline = notice.applicationDeadline;
    if (deadline == null) {
      return ExcludeSemantics(
        child: Text(
          '—',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 19, height: 1.25, fontWeight: FontWeight.w700, color: c.faint),
        ),
      );
    }
    final left = daysLeft(notice, today);
    final color = group == SavedGroup.past ? c.muted : (left != null && left <= urgentDays ? c.urgent : c.accent);
    final week = group == SavedGroup.thisWeek || group == SavedGroup.nextWeek;
    return Column(
      children: [
        Text(
          '${deadline.day.day}',
          style: TextStyle(fontSize: 19, height: 1.25, fontWeight: FontWeight.w700, color: color),
        ),
        Text(
          week ? weekdayName(deadline.day) : '${deadline.day.month}월',
          style: TextStyle(fontSize: 12, color: c.muted),
        ),
      ],
    );
  }
}
