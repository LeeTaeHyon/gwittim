import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repository.dart';
import 'common.dart';
import 'detail_screen.dart';
import 'format.dart';

/// 추천 피드. 순서는 서버(추천 함수)가 정한 그대로 보여준다.
class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key, required this.repository, required this.openUrl, this.today});

  final NoticeRepository repository;
  final OpenUrl openUrl;

  /// 테스트용. 기본은 기기 날짜.
  final DateTime? today;

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  late Future<(RecommendationList, Map<String, String>)> _future = _load();

  Future<(RecommendationList, Map<String, String>)> _load() async =>
      (await widget.repository.listRecommendations(), await widget.repository.categoryNames());

  Future<void> _reload() async {
    final next = _load();
    setState(() {
      _future = next;
    });
    try {
      await next;
    } catch (_) {
      // 오류는 FutureBuilder가 화면에 표시한다.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('귀띔')),
      body: FutureBuilder(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return MessageView(icon: Icons.cloud_off, message: errorMessage(snapshot.error!), onRetry: _reload);
          }
          final (list, categories) = snapshot.data!;
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (!list.personalized)
                  const ListTile(
                    leading: Icon(Icons.person_outline),
                    title: Text('프로필을 입력하면 맞춤 추천을 받을 수 있어요'),
                    subtitle: Text('지금은 최신 공고 순으로 보여드려요'),
                  ),
                if (list.items.isEmpty)
                  const MessageView(icon: Icons.inbox_outlined, message: '지금 보여드릴 공고가 없어요.'),
                for (final entry in list.items)
                  _NoticeCard(
                    entry: entry,
                    categoryName: categories[entry.notice.category] ?? entry.notice.category,
                    today: widget.today ?? DateTime.now(),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => DetailScreen(
                          repository: widget.repository,
                          noticeId: entry.notice.noticeId,
                          recommendation: entry.recommendation,
                          openUrl: widget.openUrl,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.entry, required this.categoryName, required this.today, required this.onTap});

  final RecommendationEntry entry;
  final String categoryName;
  final DateTime today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final n = entry.notice;
    final r = entry.recommendation;
    final dday = daysLeftLabel(n, today);
    final reason = r.reasonCodes.isEmpty ? null : reasonText(r.reasonCodes.first);
    final text = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(spacing: 6, runSpacing: 4, children: [
                StatusChip(label: categoryName),
                StatusChip(label: eligibilityLabel(r.eligibilityStatus), warning: r.eligibilityStatus != 'met'),
                if (dday != null) StatusChip(label: dday, warning: true),
              ]),
              const SizedBox(height: 8),
              Text(n.title, style: text.titleMedium),
              const SizedBox(height: 4),
              Text(deadlineLabel(n), style: text.bodySmall),
              if (reason != null && reason.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(reason, style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
