import 'package:flutter/material.dart';

import '../data/cached_repository.dart';
import '../data/models.dart';
import '../data/repository.dart';
import 'briefing_data.dart';
import 'briefing_screen.dart';
import 'briefing_stats.dart';
import 'common.dart';
import 'components.dart';
import 'external_search_screen.dart';
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
    this.picks = const MajorPickState(),
  });

  final RecommendationList list;
  final Map<String, String> categories;
  final List<SavedEntry> saved;
  final UserProfile? profile;
  final Map<String, String> majors;

  /// 학과 통계 추천에 대한 기기 기록 (D-021)
  final MajorPickState picks;
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
    this.onSetupProfile,
    this.onShowAll,
  });

  final NoticeRepository repository;
  final OpenUrl openUrl;
  final BriefingStore briefingStore;

  /// 테스트용. 기본은 기기 날짜.
  final DateTime? today;
  final VoidCallback? onOpenProfile;

  /// 서버에 프로필이 없을 때 처음 한 번 부른다 (로그인 모드의 첫 안내). 끝나면 홈을 다시 받는다.
  final Future<void> Function()? onSetupProfile;

  /// '나에게 맞는 공고' 전체 보기 (공고 탭)
  final VoidCallback? onShowAll;

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  HomeData? _data;
  Object? _error;
  bool _briefingChecked = false;

  /// 오늘 브리핑을 이미 열었는지 (자동으로 띄운 경우도 연 것). 홈 카드의 '새 소식'과 버튼 문구가 이걸 따른다.
  /// 기기 저장소를 못 읽으면 열었다고 보고 새 소식 표시를 하지 않는다.
  bool _opened = true;

  /// 프로필을 읽었고 없다고 확인된 경우만 true (읽지 못하면 미상으로 보고 안내하지 않는다)
  bool _profileMissing = false;
  bool _setupChecked = false;

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
    _profileMissing = false;
    try {
      profile = await repo.getProfile();
      _profileMissing = profile == null;
      majors = {for (final m in await repo.dictionary('majors')) m.id: m.name};
    } catch (_) {
      // 프로필 줄만 빠진다.
    }
    try {
      _opened = await widget.briefingStore.shownOn(_today);
    } catch (_) {
      _opened = true;
    }
    var picks = const MajorPickState();
    try {
      picks = await widget.briefingStore.majorPicks();
    } catch (_) {
      // 기기 저장소를 못 쓰면 답하지 않은 상태로 본다.
    }
    return HomeData(list: list, categories: categories, saved: saved, profile: profile, majors: majors, picks: picks);
  }

  /// 당겨서 새로 고침: 탭끼리 나눠 쓰는 응답도 버리고 서버에서 다시 받는다.
  Future<void> refresh() {
    forgetCached(widget.repository);
    return reload();
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
      if (_maybeSetupProfile()) return;
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

  static bool _hasInterests(HomeData data) => data.profile?.interestIds.isNotEmpty ?? false;

  Briefing _briefing(HomeData data) => buildBriefing(
    data.list,
    data.saved,
    _today,
    hasInterests: _hasInterests(data),
    picks: data.picks,
    majorId: data.profile?.majorId,
  );

  /// 학과 통계 추천에 '관심 있어요/없어요'를 답한다 (D-021). 그만 보이게 됐으면 true.
  Future<bool> _answerMajorPick(RecommendationEntry e, bool interested) async {
    final data = _data;
    if (data == null) return false;
    final majorId = data.profile?.majorId;
    final next = data.picks.answer(e.notice.noticeId, interested, majorId, _today);
    try {
      await widget.briefingStore.saveMajorPicks(next);
    } catch (_) {
      // 기기에 못 남겨도 이번 화면에서는 답한 대로 보인다.
    }
    if (mounted) {
      setState(
        () => _data = HomeData(
          list: data.list,
          categories: data.categories,
          saved: data.saved,
          profile: data.profile,
          majors: data.majors,
          picks: next,
        ),
      );
    }
    return !next.allows(majorId, _today);
  }

  /// 프로필이 없으면 브리핑보다 먼저 프로필 입력을 띄운다. 띄웠으면 true.
  /// 브리핑은 입력을 마치거나 닫은 뒤 다시 받을 때 확인한다.
  bool _maybeSetupProfile() {
    final setup = widget.onSetupProfile;
    if (_setupChecked || !_profileMissing || setup == null) return false;
    _setupChecked = true;
    setup().whenComplete(() {
      if (mounted) reload();
    });
    return true;
  }

  Future<void> _maybeShowBriefing(HomeData data) async {
    if (_briefingChecked) return;
    _briefingChecked = true;
    final briefing = _briefing(data);
    try {
      if (briefing.isEmpty || await widget.briefingStore.shownOn(_today)) return;
      await widget.briefingStore.markShown(_today);
    } catch (_) {
      return; // 기기 저장소를 못 쓰면 자동으로 띄우지 않는다 (홈 카드에서 열 수 있음)
    }
    if (mounted) _openBriefing(briefing, arrival: true);
  }

  /// [arrival]: 하루 첫 접속 때 자동으로 여는 경우만 '귀띔 도착' 장면을 보인다. 홈 카드에서 여는 경우는 장면 없음.
  Future<void> _openBriefing(Briefing briefing, {bool arrival = false}) async {
    if (!arrival) {
      try {
        await widget.briefingStore.markShown(_today); // 카드에서 연 것도 연 것으로 센다
      } catch (_) {
        // 기록하지 못해도 브리핑은 연다.
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      gwRoute(
        context,
        (_) => BriefingScreen(
          briefing: briefing,
          today: _today,
          onOpenNotice: _openNotice,
          onAnswerMajorPick: _answerMajorPick,
          arrival: arrival,
        ),
        rise: true,
      ),
    );
    if (mounted && !_opened) setState(() => _opened = true);
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
    return RefreshIndicator(onRefresh: refresh, child: _body(data));
  }

  Widget _body(HomeData data) {
    final c = context.gw;
    final caption = captionStyle(context);
    final list = data.list;
    final briefing = _briefing(data);
    // 맞춤 추천이면 관련 공고 중에서만 마감을 센다.
    final candidates = deadlineCandidates(list);
    // 학과 통계로만 고른 공고는 안내 표시를 붙여 함께 보인다 (D-021)
    final picks = {for (final e in majorPicks(list, data.picks, data.profile?.majorId, _today)) e.notice.noticeId};
    final upcoming = [
      for (final e in [...candidates, ...list.items.where((e) => picks.contains(e.notice.noticeId))])
        if ((daysLeft(e.notice, _today) ?? 99) <= 14) e,
    ]..sort((a, b) => a.notice.applicationDeadline!.date.compareTo(b.notice.applicationDeadline!.date));
    final undated = candidates.where((e) => e.notice.applicationDeadline == null).length;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _Header(profile: data.profile, majors: data.majors, today: _today, onOpenProfile: widget.onOpenProfile),
        const SizedBox(height: 16),
        if (!list.personalized) ...[_ProfilePrompt(onOpenProfile: widget.onOpenProfile), const SizedBox(height: 12)],
        // 학교를 고르지 않으면 서버가 교외 공고만 준다 (rank-0.8, D-043)
        if (data.profile?.universityId == null) ...[const SchoolHint(), const SizedBox(height: 12)],
        if (!briefing.isEmpty) ...[
          _BriefingCard(briefing: briefing, today: _today, opened: _opened, onOpen: () => _openBriefing(briefing)),
          const SizedBox(height: 28),
        ],
        SectionTitle('다가오는 마감', trailing: Text(list.personalized ? '맞춤 공고 · 앞으로 2주' : '앞으로 2주', style: caption)),
        const SizedBox(height: 12),
        GwCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (upcoming.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text(
                    keepAll(list.personalized ? '맞춤 공고 중 앞으로 2주 안에 마감되는 공고가 없습니다.' : '앞으로 2주 안에 마감되는 공고가 없습니다.'),
                    style: TextStyle(fontSize: 15, color: c.sub),
                  ),
                ),
              for (final e in upcoming)
                _UpcomingRow(
                  entry: e,
                  category: data.categories[e.notice.category] ?? e.notice.category,
                  today: _today,
                  majorPick: picks.contains(e.notice.noticeId),
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
                          keepAll('마감일이 정해지지 않은 공고 $undated개(선착순 등)는 제외했습니다.'),
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
            child: Text('표시할 공고가 없습니다.', style: TextStyle(fontSize: 15, color: c.sub)),
          ),
        for (final e in list.items.take(_homeCount)) ...[
          NoticeCard(
            entry: e,
            category: data.categories[e.notice.category] ?? e.notice.category,
            today: _today,
            home: true,
            onTap: () => _openNotice(e.notice, e.recommendation),
          ),
          const SizedBox(height: 10),
        ],
        for (final s in briefing.changed) ...[
          const SizedBox(height: 8),
          _ChangedCard(entry: s, onTap: () => _openNotice(s.notice, null)),
        ],
        const SizedBox(height: 18),
        _ExternalSearchEntry(onTap: _openExternalSearch),
      ],
    );
  }

  Future<void> _openExternalSearch() async {
    await Navigator.of(context).push(
      gwRoute(context, (_) => ExternalSearchScreen(repository: widget.repository, openUrl: widget.openUrl)),
    );
  }
}

/// 홈 맨 아래 한 줄 입구: 학교 밖 공모전·대외활동을 AI 웹 검색으로 찾는다 (D-047).
class _ExternalSearchEntry extends StatelessWidget {
  const _ExternalSearchEntry({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return GwCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          ExcludeSemantics(
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: c.chip, shape: BoxShape.circle),
              child: Icon(Icons.travel_explore_rounded, size: 22, color: c.onChip),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '학교 밖 기회 찾기',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.ink),
                ),
                const SizedBox(height: 2),
                Text('AI 웹 검색 · 크레딧 2개', style: TextStyle(fontSize: 13, color: c.muted)),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 20, color: c.muted),
        ],
      ),
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
      // 졸업이면 학년 대신 '졸업'
      if (p?.enrollmentStatus == 'graduated') '졸업' else if (p?.grade case final g?) '$g학년',
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
            keepAll('프로필을 입력하면 맞춤 추천을 받을 수 있습니다'),
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.ink),
          ),
          const SizedBox(height: 4),
          Text('현재 최신 공고 순으로 표시합니다', style: TextStyle(fontSize: 14, color: c.sub)),
          if (onOpenProfile != null) ...[
            const SizedBox(height: 12),
            SoftButton(label: '프로필 입력', onPressed: onOpenProfile!),
          ],
        ],
      ),
    );
  }
}

/// 오늘의 귀띔 (2026-11-19 개편): 브리핑 머리와 같은 hero 면 카드. 공고 제목은 다시 쓰지 않고 숫자만 보인다(2026-10-25 Q3).
/// 위: 배지·날짜(안 열었으면 '새 소식' 점) → 제목 '오늘 확인할 공고 N건' → 숫자 칸(최대 3, 0건 숨김) → 열기 버튼.
/// 카드 전체를 눌러도 브리핑이 열린다.
class _BriefingCard extends StatelessWidget {
  const _BriefingCard({required this.briefing, required this.today, required this.opened, required this.onOpen});

  final Briefing briefing;
  final DateTime today;

  /// 오늘 브리핑을 이미 열었는지
  final bool opened;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final b = briefing;
    final title = TextStyle(fontSize: 21, height: 1.45, fontWeight: FontWeight.w700, color: c.loginInk);
    final lead = b.onlyChanged ? '마감이 바뀐' : '오늘 확인할';
    final rest = b.onlyChanged ? ' 저장 공고' : ' 공고 ${distinctNoticeCount(b)}건';
    return Material(
      color: c.hero,
      borderRadius: Gw.bubble,
      child: InkWell(
        borderRadius: Gw.bubble,
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const GwBadge(),
                  const SizedBox(width: 8),
                  Text(
                    briefingDay(today),
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.loginSub),
                  ),
                  const Spacer(),
                  if (!opened) const _NewMark(),
                ],
              ),
              const SizedBox(height: 14),
              Text.rich(
                TextSpan(
                  style: title,
                  children: [
                    WidgetSpan(
                      alignment: PlaceholderAlignment.baseline,
                      baseline: TextBaseline.alphabetic,
                      child: LimeFace(lead, style: title, animate: !opened, delay: const Duration(milliseconds: 500)),
                    ),
                    TextSpan(text: keepAll(rest)), // 큰 글꼴에서 '공/고 1건'처럼 어절 중간에서 끊기지 않게
                  ],
                ),
              ),
              if (briefingStats(b).isNotEmpty) ...[const SizedBox(height: 14), BriefingStatRow(briefing: b)],
              const SizedBox(height: 14),
              _OpenButton(opened: opened, onTap: onOpen),
            ],
          ),
        ),
      ),
    );
  }
}

/// 아래 열기 버튼 (높이 48 알약). 안 열었으면 라임 면, 열었으면 투명 + 흰 28% 테두리.
class _OpenButton extends StatelessWidget {
  const _OpenButton({required this.opened, required this.onTap});

  final bool opened;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final shape = StadiumBorder(side: opened ? BorderSide(color: c.loginInk.withValues(alpha: 0.28)) : BorderSide.none);
    final fg = opened ? c.loginInk : c.limeInk;
    return Material(
      color: opened ? Colors.transparent : c.lime,
      shape: shape,
      child: InkWell(
        customBorder: shape,
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  opened ? '브리핑 다시 보기' : '브리핑 열기',
                  style: TextStyle(fontSize: 15, fontWeight: opened ? FontWeight.w600 : FontWeight.w700, color: fg),
                ),
                if (!opened) ...[const SizedBox(width: 6), Icon(Icons.arrow_forward_rounded, size: 18, color: fg)],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// '새 소식': 지름 8 라임 점과 바깥 고리. 고리가 1.6초 동안 퍼지는 것을 3번 하고 멈춘다(애니메이션 줄이기면 정지).
class _NewMark extends StatefulWidget {
  const _NewMark();

  @override
  State<_NewMark> createState() => _NewMarkState();
}

class _NewMarkState extends State<_NewMark> with SingleTickerProviderStateMixin {
  static const _rounds = 3;
  late final AnimationController _ring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600 * _rounds),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started && MediaQuery.maybeDisableAnimationsOf(context) != true) {
      _started = true;
      _ring.forward();
    }
  }

  @override
  void dispose() {
    _ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: AnimatedBuilder(
            animation: _ring,
            builder: (_, _) {
              final p = _ring.value >= 1 ? 1.0 : (_ring.value * _rounds) % 1;
              final e = Curves.easeOut.transform(p);
              return Stack(
                alignment: Alignment.center,
                children: [
                  Opacity(
                    opacity: _started ? 0.9 * (1 - e) : 0,
                    child: Transform.scale(
                      scale: 0.4 + 1.0 * e,
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: c.lime, width: 2),
                        ),
                      ),
                    ),
                  ),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: c.lime, shape: BoxShape.circle),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(width: 2),
        Text(
          '새 소식',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.loginInk),
        ),
      ],
    );
  }
}

class _UpcomingRow extends StatelessWidget {
  const _UpcomingRow({
    required this.entry,
    required this.category,
    required this.today,
    required this.onTap,
    this.majorPick = false,
  });

  final RecommendationEntry entry;
  final String category;
  final DateTime today;
  final VoidCallback onTap;

  /// 학과 통계로만 고른 공고 (D-021): 제목 위에 안내 표시
  final bool majorPick;

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
            // 날짜 블록: 위 칸에 월, 아래에 큰 날짜. 7일 안이면 빨강. 줄 글자에 D-day가 있어 화면 읽기에서는 뺀다.
            ExcludeSemantics(
              child: Container(
                width: 44,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(color: c.neutral, borderRadius: BorderRadius.circular(12)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      color: urgent ? c.urgentSoft : c.chip,
                      alignment: Alignment.center,
                      child: Text(
                        '${day.month}월',
                        style: TextStyle(fontSize: 11, height: 1.3, fontWeight: FontWeight.w700, color: fg),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        '${day.day}',
                        style: TextStyle(
                          fontSize: 19,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                          color: urgent ? c.urgent : c.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (majorPick) ...[const MajorPickLabel(), const SizedBox(height: 4)],
                  Text(
                    keepAll(n.title),
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
                      keepAll('${entry.notice.title}${now == null ? '' : ' · 이제 ${shortDate(now)}까지'}'),
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
