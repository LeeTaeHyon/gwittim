import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repository.dart';
import 'briefing_data.dart';
import 'briefing_screen.dart';
import 'common.dart';
import 'components.dart';
import 'format.dart';
import 'report_screen.dart';
import 'theme.dart';

/// 홈에 필요한 응답 묶음. 저장 목록·프로필을 못 읽어도 추천은 보여준다.
class HomeData {
  const HomeData({
    required this.list,
    required this.categories,
    required this.saved,
    required this.profile,
    required this.majors,
  });

  final RecommendationList list;
  final Map<String, String> categories;
  final List<SavedEntry> saved;
  final UserProfile? profile;
  final Map<String, String> majors;
}

/// 홈 (D-009): 오늘의 귀띔 → 다가오는 마감 → 나에게 맞는 공고 → 저장한 공고 마감 변경.
/// 추천 순서는 서버가 정한 그대로 보여준다.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.repository,
    required this.openUrl,
    required this.briefingStore,
    this.today,
    this.onOpenProfile,
  });

  final NoticeRepository repository;
  final OpenUrl openUrl;
  final BriefingStore briefingStore;

  /// 테스트용. 기본은 기기 날짜.
  final DateTime? today;
  final VoidCallback? onOpenProfile;

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  HomeData? _data;
  Object? _error;
  bool _briefingChecked = false;

  DateTime get _today => widget.today ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<HomeData> _load() async {
    final repo = widget.repository;
    final list = await repo.listRecommendations();
    final categories = await repo.categoryNames();
    List<SavedEntry> saved = const [];
    UserProfile? profile;
    var majors = const <String, String>{};
    try {
      saved = await repo.listSaved();
    } catch (_) {
      // 저장 목록을 못 읽어도 추천은 보여준다.
    }
    try {
      profile = await repo.getProfile();
      majors = {for (final m in await repo.dictionary('majors')) m.id: m.name};
    } catch (_) {
      // 프로필 줄만 빠진다.
    }
    return HomeData(list: list, categories: categories, saved: saved, profile: profile, majors: majors);
  }

  /// 프로필 저장·공고 저장 후 다시 받는다. 이미 보이는 내용은 받는 동안 그대로 둔다.
  Future<void> reload() async {
    try {
      final data = await _load();
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
      });
      _maybeShowBriefing(data);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _maybeShowBriefing(HomeData data) async {
    if (_briefingChecked) return;
    _briefingChecked = true;
    final briefing = buildBriefing(data.list, data.saved, _today);
    try {
      if (briefing.isEmpty || await widget.briefingStore.shownOn(_today)) return;
      await widget.briefingStore.markShown(_today);
    } catch (_) {
      return; // 기기 저장소를 못 쓰면 자동으로 띄우지 않는다 (홈 카드에서 열 수 있음)
    }
    if (mounted) _openBriefing(briefing);
  }

  void _openBriefing(Briefing briefing) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => BriefingScreen(briefing: briefing, today: _today, onOpenNotice: _openNotice),
      ),
    );
  }

  Future<void> _openNotice(NoticeSummary notice, Recommendation? recommendation) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReportScreen(
          repository: widget.repository,
          noticeId: notice.noticeId,
          recommendation: recommendation,
          openUrl: widget.openUrl,
          today: widget.today,
        ),
      ),
    );
    reload();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) {
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
    return RefreshIndicator(onRefresh: reload, child: _body(data));
  }

  Widget _body(HomeData data) {
    final list = data.list;
    final briefing = buildBriefing(list, data.saved, _today);
    final upcoming = [
      for (final e in list.items)
        if ((daysLeft(e.notice, _today) ?? 99) <= 14) e,
    ]..sort((a, b) => a.notice.applicationDeadline!.date.compareTo(b.notice.applicationDeadline!.date));
    final undated = list.items.where((e) => e.notice.applicationDeadline == null).length;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _Header(profile: data.profile, majors: data.majors, today: _today),
        const SizedBox(height: 16),
        if (!list.personalized) ...[_ProfilePrompt(onOpenProfile: widget.onOpenProfile), const SizedBox(height: 12)],
        if (!briefing.isEmpty) ...[
          _BriefingCard(briefing: briefing, today: _today, onOpen: () => _openBriefing(briefing)),
          const SizedBox(height: 28),
        ],
        const SectionTitle('다가오는 마감', trailing: Text('앞으로 2주', style: captionStyle)),
        const SizedBox(height: 12),
        GwCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (upcoming.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Text('앞으로 2주 안에 마감되는 공고가 없어요.', style: TextStyle(fontSize: 15, color: Gw.sub)),
                ),
              for (final e in upcoming)
                _UpcomingRow(
                  entry: e,
                  category: data.categories[e.notice.category] ?? e.notice.category,
                  today: _today,
                  onTap: () => _openNotice(e.notice, e.recommendation),
                ),
              if (undated > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: Text('마감일이 정해지지 않은 공고 $undated개(선착순 등)는 넣지 않았어요.', style: captionStyle),
                ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        SectionTitle(
          list.personalized ? '나에게 맞는 공고' : '최신 공고',
          trailing: Text(list.personalized ? '추천순' : '최신순', style: captionStyle),
        ),
        const SizedBox(height: 12),
        if (list.items.isEmpty)
          const GwCard(
            child: Text('지금 보여드릴 공고가 없어요.', style: TextStyle(fontSize: 15, color: Gw.sub)),
          ),
        for (final e in list.items) ...[
          _NoticeCard(
            entry: e,
            category: data.categories[e.notice.category] ?? e.notice.category,
            today: _today,
            onTap: () => _openNotice(e.notice, e.recommendation),
          ),
          const SizedBox(height: 10),
        ],
        for (final s in briefing.changed) ...[
          const SizedBox(height: 8),
          _ChangedCard(entry: s, onTap: () => _openNotice(s.notice, null)),
        ],
        if (list.personalized) ...[
          const SizedBox(height: 16),
          const Text('추천 순서는 관심사·희망 직무·전공·마감 시기로 정해요. 합격 가능성을 뜻하지 않아요.', style: captionStyle),
        ],
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.profile, required this.majors, required this.today});

  final UserProfile? profile;
  final Map<String, String> majors;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final who = [
      if (p?.majorId case final m?) majors[m] ?? '',
      if (p?.grade case final g?) '$g학년',
    ].where((s) => s.isNotEmpty).join(' ');
    return Row(
      children: [
        const GwBadge(),
        const SizedBox(width: 8),
        Text(
          shortDay(today),
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Gw.muted),
        ),
        const Spacer(),
        if (who.isNotEmpty)
          Text(
            who,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Gw.sub),
          ),
      ],
    );
  }
}

class _ProfilePrompt extends StatelessWidget {
  const _ProfilePrompt({required this.onOpenProfile});

  final VoidCallback? onOpenProfile;

  @override
  Widget build(BuildContext context) {
    return GwCard(
      bubble: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '프로필을 입력하면 맞춤 추천을 받을 수 있어요',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Gw.ink),
          ),
          const SizedBox(height: 4),
          const Text('지금은 최신 공고 순으로 보여드려요', style: TextStyle(fontSize: 14, color: Gw.sub)),
          if (onOpenProfile != null) ...[
            const SizedBox(height: 12),
            SoftButton(label: '프로필 입력', onPressed: onOpenProfile!),
          ],
        ],
      ),
    );
  }
}

class _BriefingCard extends StatelessWidget {
  const _BriefingCard({required this.briefing, required this.today, required this.onOpen});

  final Briefing briefing;
  final DateTime today;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    const line = TextStyle(fontSize: 15, height: 1.5, color: Gw.body);
    final urgent = briefing.urgent;
    return GwCard(
      bubble: true,
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '오늘의 귀띔',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Gw.navy),
          ),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: Gw.ink, height: 1.4),
              children: [
                const TextSpan(text: '오늘 챙길 소식 '),
                markSpan(
                  '${briefing.count}가지',
                  const TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: Gw.ink),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (urgent != null)
            Text(
              '• ${urgent.notice.title} 마감 ${_dday(urgent.notice, today)}',
              style: line,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          if (briefing.related.isNotEmpty) Text('• 관심 분야·직무·전공 관련 공고 ${briefing.related.length}개', style: line),
          if (briefing.changed.isNotEmpty) Text('• 저장한 공고 ${briefing.changed.length}개 마감이 바뀜', style: line),
          const SizedBox(height: 12),
          SoftButton(label: '브리핑 보기', onPressed: onOpen),
        ],
      ),
    );
  }
}

String _dday(NoticeSummary n, DateTime today) {
  final left = daysLeft(n, today);
  return left == null ? '' : (left == 0 ? '오늘' : 'D-$left');
}

class _UpcomingRow extends StatelessWidget {
  const _UpcomingRow({required this.entry, required this.category, required this.today, required this.onTap});

  final RecommendationEntry entry;
  final String category;
  final DateTime today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final n = entry.notice;
    final day = n.applicationDeadline!.day;
    final left = daysLeft(n, today)!;
    final urgent = left <= urgentDays;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: urgent ? Gw.urgentSoft : Gw.navySoft, shape: BoxShape.circle),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    weekdayName(day),
                    style: TextStyle(fontSize: 11, height: 1.1, color: urgent ? Gw.urgent : Gw.navy),
                  ),
                  Text(
                    '${day.day}',
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.1,
                      fontWeight: FontWeight.w700,
                      color: urgent ? Gw.urgent : Gw.navy,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    n.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Gw.body, height: 1.4),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      category,
                      left == 0 ? '오늘 마감' : 'D-$left',
                      if (n.applicationDeadline!.hasTime) '${n.applicationDeadline!.time} 마감',
                      eligibilityShort(entry.recommendation.eligibilityStatus),
                    ].join(' · '),
                    style: const TextStyle(fontSize: 13, color: Gw.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.entry, required this.category, required this.today, required this.onTap});

  final RecommendationEntry entry;
  final String category;
  final DateTime today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final n = entry.notice;
    final r = entry.recommendation;
    final dday = ddayPill(n, today);
    final reason = r.reasonCodes.map(reasonText).firstWhere((t) => t.isNotEmpty, orElse: () => '');
    final deadline = n.applicationDeadline;
    return GwCard(
      onTap: onTap,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ?dday,
              Pill(category, background: Gw.bg, foreground: Gw.sub),
              eligibilityPill(r.eligibilityStatus),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            n.title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Gw.ink, height: 1.45),
          ),
          const SizedBox(height: 4),
          Text(
            deadline != null ? '${shortDate(deadline)}까지' : (n.deadlineNote ?? '마감일이 공고에 나와 있지 않아요'),
            style: const TextStyle(fontSize: 14, color: Gw.sub),
          ),
          if (reason.isNotEmpty && r.reasonCodes.any(personalReasons.containsKey)) ...[
            const SizedBox(height: 4),
            Text(
              reason,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Gw.navy),
            ),
          ],
        ],
      ),
    );
  }
}

class _ChangedCard extends StatelessWidget {
  const _ChangedCard({required this.entry, required this.onTap});

  final SavedEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final now = entry.notice.applicationDeadline;
    return Material(
      color: Gw.navySoft,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.alarm, color: Gw.urgent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '저장한 공고의 ${deadlineChangeText(entry)}',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Gw.body),
                    ),
                    Text(
                      '${entry.notice.title}${now == null ? '' : ' · 이제 ${shortDate(now)}까지'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: Gw.sub),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
