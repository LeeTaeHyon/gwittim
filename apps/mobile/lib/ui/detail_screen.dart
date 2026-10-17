import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repository.dart';
import 'common.dart';
import 'format.dart';

class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.repository,
    required this.noticeId,
    required this.openUrl,
    this.recommendation,
  });

  final NoticeRepository repository;
  final String noticeId;
  final OpenUrl openUrl;

  /// 피드에서 들어온 경우 추천 이유를 함께 보여준다.
  final Recommendation? recommendation;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late Future<Notice?> _future = widget.repository.getNotice(widget.noticeId);
  bool? _saved;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    try {
      final saved = await widget.repository.listSaved();
      if (mounted) setState(() => _saved = saved.any((e) => e.notice.noticeId == widget.noticeId));
    } catch (_) {
      // 저장 상태를 못 읽어도 상세는 보여준다.
    }
  }

  Future<void> _toggleSave() async {
    final messenger = ScaffoldMessenger.of(context);
    final wasSaved = _saved == true;
    try {
      if (wasSaved) {
        await widget.repository.deleteSaved(widget.noticeId);
      } else {
        await widget.repository.saveNotice(widget.noticeId);
      }
      if (!mounted) return;
      setState(() => _saved = !wasSaved);
      messenger.showSnackBar(SnackBar(content: Text(wasSaved ? '저장을 취소했어요.' : '저장했어요.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(e))));
    }
  }

  Future<void> _open(Notice notice) async {
    final ok = await widget.openUrl(Uri.parse(notice.summary.sourceUrl));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('원문을 열지 못했어요.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('공고 상세'),
        actions: [
          if (_saved != null)
            IconButton(
              tooltip: _saved! ? '저장 취소' : '저장',
              icon: Icon(_saved! ? Icons.bookmark : Icons.bookmark_border),
              onPressed: _toggleSave,
            ),
        ],
      ),
      body: FutureBuilder(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return MessageView(
              icon: Icons.cloud_off,
              message: errorMessage(snapshot.error!),
              onRetry: () => setState(() {
                _future = widget.repository.getNotice(widget.noticeId);
              }),
            );
          }
          final notice = snapshot.data;
          if (notice == null) {
            return const MessageView(icon: Icons.search_off, message: '공고를 찾을 수 없어요.');
          }
          return _DetailBody(notice: notice, recommendation: widget.recommendation, onOpen: () => _open(notice));
        },
      ),
    );
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({required this.notice, required this.recommendation, required this.onOpen});

  final Notice notice;
  final Recommendation? recommendation;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final n = notice.summary;
    final text = Theme.of(context).textTheme;
    final elig = notice.eligibility;
    final reasons = [for (final c in recommendation?.reasonCodes ?? const <String>[]) reasonText(c)]
        .where((r) => r.isNotEmpty)
        .toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 6,
          children: [
            StatusChip(label: lifecycleLabel(n.lifecycleStatus), warning: n.lifecycleStatus != 'open'),
            if (recommendation != null)
              StatusChip(
                label: eligibilityLabel(recommendation!.eligibilityStatus),
                warning: recommendation!.eligibilityStatus != 'met',
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(n.title, style: text.titleLarge),
        if (notice.description != null) ...[const SizedBox(height: 8), Text(notice.description!)],
        const Divider(height: 32),
        _Row(label: '마감', value: deadlineLabel(n).replaceFirst('마감 ', '')),
        if (notice.applicationStart != null) _Row(label: '신청 시작', value: formatDateInfo(notice.applicationStart!)),
        if (n.applicationDeadline != null && n.deadlineNote != null) _Row(label: '마감 안내', value: n.deadlineNote!),
        if (notice.activityPeriod case final p?)
          _Row(label: '활동 기간', value: [p.start, p.end].whereType<DateInfo>().map(formatDateInfo).join(' ~ ')),
        if (n.published != null) _Row(label: '게시일', value: formatDateInfo(n.published!)),
        const Divider(height: 32),
        Text('지원 조건', style: text.titleMedium),
        const SizedBox(height: 8),
        if (elig.explicitlyUnrestricted)
          Text('제한 없음 — "${elig.unrestrictedEvidence}"')
        else if (elig.conditions.isEmpty)
          const Text('공고에서 지원 조건을 찾지 못했어요. 원문을 확인해 주세요.')
        else
          for (final c in elig.conditions) _Row(label: conditionFieldLabel(c.field), value: c.evidence),
        for (final u in elig.unresolvedEvidence) _Row(label: '추가 조건', value: u),
        if (!elig.extractionComplete)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '첨부파일·이미지에 조건이 더 있을 수 있어요. 지원 전에 원문을 확인해 주세요.',
              style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.tertiary),
            ),
          ),
        if (reasons.isNotEmpty) ...[
          const Divider(height: 32),
          Text('추천 이유', style: text.titleMedium),
          const SizedBox(height: 8),
          for (final r in reasons) Text('• $r'),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(onPressed: onOpen, icon: const Icon(Icons.open_in_new), label: const Text('원문 보기')),
        if (notice.lastVerifiedAt != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '원문 확인: ${notice.lastVerifiedAt!.toLocal().toString().substring(0, 16)}',
              style: text.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 72, child: Text(label, style: Theme.of(context).textTheme.labelLarge)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
