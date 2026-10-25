import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repository.dart';
import 'briefing_data.dart';
import 'briefing_screen.dart';
import 'common.dart';
import 'components.dart';
import 'format.dart';
import 'icons.dart';
import 'notices_screen.dart';
import 'report_screen.dart';
import 'skeleton.dart';
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

/// 홈 (D-009): 오늘의 귀띔(숫자 요약) → 다가오는 마감 → 나에게 맞는 공고 상위 3개 → 저장한 공고 마감 변경.
/// 추천 순서는 서버가 정한 그대로 보여주고, 전체 목록은 공고 탭에 있다 (2026-10-25 팀장 결정 Q1 B·Q3).
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.repository,
    required this.openUrl,
    required this.briefingStore,
    this.today,
    this.onOpenProfile,
    this.onShowAll,
  });

  final NoticeRepository repository;
  final OpenUrl openUrl;
  final BriefingStore briefingStore;

  /// 테스트용. 기본은 기기 날짜.
  final DateTime? today;
  final VoidCallback? onOpenProfile;

  /// '나에게 맞는 공고' 전체 보기 (공고 탭)
  final VoidCallback? onShowAll;

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
      if (!mounted) return;
      if (_data != null) {
        showRefreshFailed(context, e); // 보이던 내용은 그대로 둔다
      } else {
        setState(() => _error = e);
      }
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
      gwRoute(context, (_) => BriefingScreen(briefing: briefing, today: _today, onOpenNotice: _openNotice), rise: true),
    );
  }

  Future<void> _openNotice(NoticeSummary notice, Recommendation? recommendation) async {
    await Navigator.of(context).push(
      gwRoute(
        context,
        (_) => ReportScreen(
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
        return MessageView.error(
          _error!,
          onRetry: () {
            setState(() => _error = null);
            reload();
          },
        );
      }
      return const HomeSkeleton();
    }
    return RefreshIndicator(onRefresh: reload, child: _body(data));
  }

  Widget _body(HomeData data) {
    final c = context.gw;
    final caption = captionStyle(context);
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
        _Header(profile: data.profile, majors: data.majors, today: _today, onOpenProfile: widget.onOpenProfile),
        const SizedBox(height: 16),
        if (!list.personalized) ...[_ProfilePrompt(onOpenProfile: widget.onOpenProfile), const SizedBox(height: 12)],
        if (!briefing.isEmpty) ...[
          _BriefingCard(
            briefing: briefing,
            urgentCount: list.items.where((e) => (daysLeft(e.notice, _today) ?? 99) <= urgentDays).length,
            onOpen: () => _openBriefing(briefing),
          ),
          const SizedBox(height: 28),
        ],
        SectionTitle('다가오는 마감', trailing: Text('앞으로 2주', style: caption)),
        const SizedBox(height: 12),
        GwCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (upcoming.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text('앞으로 2주 안에 마감되는 공고가 없어요.', style: TextStyle(fontSize: 15, color: c.sub)),
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
                  padding: const EdgeInsets.only(top: 6, bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Icon(Icons.info_outline_rounded, size: 15, color: c.muted),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '마감일이 정해지지 않은 공고 $undated개(선착순 등)는 넣지 않았어요.',
                          style: TextStyle(fontSize: 13, height: 1.5, color: c.muted),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        SectionTitle(
          list.personalized ? '나에게 맞는 공고' : '최신 공고',
          trailing: list.items.length > _homeCount && widget.onShowAll != null
              ? _ShowAll(onTap: widget.onShowAll!)
              : Text(list.personalized ? '추천순' : '최신순', style: caption),
        ),
        const SizedBox(height: 12),
        if (list.items.isEmpty)
          GwCard(
            child: Text('지금 보여드릴 공고가 없어요.', style: TextStyle(fontSize: 15, color: c.sub)),
          ),
        for (final e in list.items.take(_homeCount)) ...[
          NoticeCard(
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
      ],
    );
  }
}

/// 홈에 보이는 맞춤 공고 수. 나머지는 공고 탭에서 본다.
const _homeCount = 3;

class _ShowAll extends StatelessWidget {
  const _ShowAll({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: c.sub,
        minimumSize: const Size(48, 40),
        padding: const EdgeInsets.only(left: 10, right: 4),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontFamily: 'Pretendard', fontSize: 14, fontWeight: FontWeight.w600),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [Text('전체 보기'), Icon(Icons.chevron_right_rounded, size: 18)],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.profile, required this.majors, required this.today, this.onOpenProfile});

  final UserProfile? profile;
  final Map<String, String> majors;
  final DateTime today;
  final VoidCallback? onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
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
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.muted),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            who,
            textAlign: TextAlign.end,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.sub),
          ),
        ),
        if (onOpenProfile != null)
          IconButton(
            tooltip: '내 정보',
            onPressed: onOpenProfile,
            icon: GwIcon(GwGlyph.profile, color: c.ink),
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
    final c = context.gw;
    return GwCard(
      bubble: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '프로필을 입력하면 맞춤 추천을 받을 수 있어요',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.ink),
          ),
          const SizedBox(height: 4),
          Text('지금은 최신 공고 순으로 보여드려요', style: TextStyle(fontSize: 14, color: c.sub)),
          if (onOpenProfile != null) ...[
            const SizedBox(height: 12),
            SoftButton(label: '프로필 입력', onPressed: onOpenProfile!),
          ],
        ],
      ),
    );
  }
}

/// 오늘의 귀띔: 숫자 요약만 보이고 공고 제목은 다시 쓰지 않는다 (2026-10-25 팀장 결정 Q3).
class _BriefingCard extends StatelessWidget {
  const _BriefingCard({required this.briefing, required this.urgentCount, required this.onOpen});

  final Briefing briefing;

  /// 7일 안에 마감되는 공고 수
  final int urgentCount;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final headline = TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: c.ink, height: 1.4);
    return GwCard(
      bubble: true,
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '오늘의 귀띔',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.accent),
          ),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              style: headline,
              children: [
                const TextSpan(text: '오늘 챙길 소식 '),
                markSpan('${briefing.count}가지', headline),
              ],
            ),
          ),
          const SizedBox(height: 14),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _Stat(count: urgentCount, label: '마감 임박', urgent: urgentCount > 0),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Stat(count: briefing.related.length, label: '맞춤 공고'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Stat(count: briefing.changed.length, label: '마감 바뀐\n저장 공고'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SoftButton(label: '브리핑 보기', onPressed: onOpen),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.count, required this.label, this.urgent = false});

  final int count;
  final String label;
  final bool urgent;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return MergeSemantics(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(color: c.neutral, borderRadius: BorderRadius.circular(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$count개',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: count == 0 ? c.muted : (urgent ? c.urgent : c.ink),
              ),
            ),
            const SizedBox(height: 2),
            Text(label, maxLines: 2, style: TextStyle(fontSize: 12, height: 1.35, color: c.sub)),
          ],
        ),
      ),
    );
  }
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
    final c = context.gw;
    final fg = urgent ? c.urgent : c.onChip;
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
              decoration: BoxDecoration(color: urgent ? c.urgentSoft : c.chip, shape: BoxShape.circle),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(weekdayName(day), style: TextStyle(fontSize: 11, height: 1.1, color: fg)),
                  Text(
                    '${day.day}',
                    style: TextStyle(fontSize: 16, height: 1.1, fontWeight: FontWeight.w700, color: fg),
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
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.body, height: 1.4),
                  ),
                  const SizedBox(height: 2),
                  // 남은 날과 시각을 앞에 굵게, 분류와 확인 필요는 뒤에 흐리게
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: [
                            left == 0 ? '오늘 마감' : 'D-$left',
                            if (n.applicationDeadline!.hasTime) '${n.applicationDeadline!.time} 마감',
                          ].join(' · '),
                          style: TextStyle(fontWeight: FontWeight.w600, color: urgent ? c.urgent : c.sub),
                        ),
                        TextSpan(text: ' · $category'),
                        if (entry.recommendation.eligibilityStatus != 'met')
                          TextSpan(text: ' · ${eligibilityShort(entry.recommendation.eligibilityStatus)}'),
                      ],
                    ),
                    style: TextStyle(fontSize: 13, color: c.muted),
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

class _ChangedCard extends StatelessWidget {
  const _ChangedCard({required this.entry, required this.onTap});

  final SavedEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final now = entry.notice.applicationDeadline;
    final c = context.gw;
    return Material(
      color: c.chip,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.alarm_rounded, color: c.urgent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '저장한 공고의 ${deadlineChangeText(entry)}',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.body),
                    ),
                    Text(
                      '${entry.notice.title}${now == null ? '' : ' · 이제 ${shortDate(now)}까지'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: c.sub),
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
