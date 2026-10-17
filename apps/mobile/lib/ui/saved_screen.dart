import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repository.dart';
import 'common.dart';
import 'detail_screen.dart';
import 'format.dart';

/// 저장한 공고를 마감일 순으로 보여준다. 최신 공고 상태와 저장 이후 바뀐 마감을 함께 표시한다 (SPEC §6).
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

class SavedScreenState extends State<SavedScreen> {
  late Future<List<SavedEntry>> _future = widget.repository.listSaved();

  void reload() => setState(() {
    _future = widget.repository.listSaved();
  });

  Future<void> _remove(SavedEntry e) async {
    await widget.repository.deleteSaved(e.notice.noticeId);
    reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return MessageView(icon: Icons.cloud_off, message: errorMessage(snapshot.error!), onRetry: reload);
        }
        final entries = sortByDeadline(snapshot.data!);
        if (entries.isEmpty) {
          return const MessageView(icon: Icons.bookmark_border, message: '저장한 공고가 없어요.\n공고 상세에서 저장할 수 있어요.');
        }
        final today = widget.today ?? DateTime.now();
        return ListView(
          children: [
            for (final e in entries)
              ListTile(
                title: Text(e.notice.title),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(deadlineLabel(e.notice)),
                    if (e.deadlineChanged)
                      Text(
                        '마감이 바뀌었어요 (저장 당시: ${e.saved.savedDeadlineSnapshot == null ? '미상' : formatDateInfo(e.saved.savedDeadlineSnapshot!)})',
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                      ),
                    if (e.notice.lifecycleStatus != 'open') Text(lifecycleLabel(e.notice.lifecycleStatus)),
                  ],
                ),
                isThreeLine: e.deadlineChanged || e.notice.lifecycleStatus != 'open',
                leading: SizedBox(
                  width: 52,
                  child: Center(child: Text(daysLeftLabel(e.notice, today) ?? '-', textAlign: TextAlign.center)),
                ),
                trailing: IconButton(
                  tooltip: '저장 취소',
                  icon: const Icon(Icons.bookmark_remove_outlined),
                  onPressed: () => _remove(e),
                ),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DetailScreen(
                        repository: widget.repository,
                        noticeId: e.notice.noticeId,
                        openUrl: widget.openUrl,
                      ),
                    ),
                  );
                  reload();
                },
              ),
          ],
        );
      },
    );
  }
}
