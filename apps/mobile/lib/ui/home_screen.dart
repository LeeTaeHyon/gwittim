import 'package:flutter/material.dart';

import '../data/cached_repository.dart';
import '../data/models.dart';
import '../data/repository.dart';
import 'briefing_data.dart';
import 'briefing_screen.dart';
import 'common.dart';
import 'components.dart';
import 'format.dart';
import 'home_sections.dart';
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

/// 홈 (D-009, D-050): 귀띔 말풍선(달라진 것의 건수) → 이번 주 마감 → 새 공고 → 마감이 먼 맞춤 공고 → 저장한 공고 마감 변경.
/// 마감순 한 목록이고 같은 공고는 홈에서 한 번만 나온다. 줄을 고르는 계산은 [buildHomeSections].
/// 추천 순서는 서버가 정한 그대로 쓰고, 전체 목록은 공고 탭에 있다 (2026-10-25 팀장 결정 Q1 B·Q3).
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
    this.onShowCalendar,
  });

  final NoticeRepository repository;
  final OpenUrl openUrl;
  final BriefingStore briefingStore;

  /// 테스트용. 기본은 기기 날짜.
  final DateTime? today;
  final VoidCallback? onOpenProfile;

  /// 서버에 프로필이 없을 때 처음 한 번 부른다 (로그인 모드의 첫 안내). 끝나면 홈을 다시 받는다.
  final Future<void> Function()? onSetupProfile;

  /// '마감이 먼 맞춤 공고' 전체 보기 (공고 탭)
  final VoidCallback? onShowAll;

  /// '이번 주 마감' 전체 N건 (달력 탭)
  final VoidCallback? onShowCalendar;

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  HomeData? _data;
  Object? _error;
  bool _briefingChecked = false;

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
      return; // 기기 저장소를 못 쓰면 자동으로 띄우지 않는다 (말풍선이 있으면 거기서 열 수 있음)
    }
    if (mounted) _openBriefing(briefing, arrival: true);
  }

  /// [arrival]: 하루 첫 접속 때 자동으로 여는 경우만 '귀띔 도착' 장면을 보인다. 홈 말풍선에서 여는 경우는 장면 없음.
  Future<void> _openBriefing(Briefing briefing, {bool arrival = false}) async {
    if (!arrival) {
      try {
        await widget.briefingStore.markShown(_today); // 말풍선으로 연 것도 연 것으로 센다
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
    final home = buildHomeSections(list, data.saved, _today, picks: data.picks, majorId: data.profile?.majorId);
    final weekRows = list.personalized ? homeWeekRows : homeLatestRows;

    Widget line(HomeRow r, {required bool dated}) => _HomeLine(
      row: r,
      category: data.categories[r.notice.category] ?? r.notice.category,
      today: _today,
      personalized: list.personalized,
      dated: dated,
      onTap: () => _openNotice(r.notice, r.recommendation),
    );

    Widget rows(List<Widget> children) => GwCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );

    final Widget deadlineTrailing = home.isNext
        ? Text('앞으로 2주', style: caption)
        : home.weekTotal > weekRows && widget.onShowCalendar != null
        ? _ShowAll(label: '전체 ${home.weekTotal}건', onTap: widget.onShowCalendar!)
        : Text('앞으로 7일', style: caption);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _Header(profile: data.profile, majors: data.majors, today: _today, onOpenProfile: widget.onOpenProfile),
        const SizedBox(height: 16),
        if (!list.personalized) ...[_ProfilePrompt(onOpenProfile: widget.onOpenProfile), const SizedBox(height: 12)],
        // 학교를 고르지 않으면 서버가 교외 공고만 준다 (rank-0.8, D-043)
        if (data.profile?.universityId == null) ...[const SchoolHint(), const SizedBox(height: 12)],
        if (home.nudge case final nudge?) ...[
          _Nudge(nudge: nudge, onOpen: () => _openBriefing(_briefing(data))),
          const SizedBox(height: 28),
        ],
        SectionTitle(home.isNext ? '다음 마감' : (list.personalized ? '이번 주 마감' : '곧 마감되는 공고'), trailing: deadlineTrailing),
        const SizedBox(height: 12),
        rows([
          if (home.deadlines.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                keepAll(list.personalized ? '맞춤 공고 중 앞으로 2주 안에 마감되는 공고가 없습니다.' : '앞으로 2주 안에 마감되는 공고가 없습니다.'),
                style: TextStyle(fontSize: 15, color: c.sub),
              ),
            ),
          for (final r in home.deadlines) line(r, dated: true),
        ]),
        if (home.fresh.isNotEmpty) ...[
          const SizedBox(height: 28),
          SectionTitle('새 공고', trailing: Text('최근 3일', style: caption)),
          const SizedBox(height: 12),
          rows([for (final r in home.fresh) line(r, dated: false)]),
        ],
        if (home.later.isNotEmpty) ...[
          const SizedBox(height: 28),
          SectionTitle(
            '마감이 먼 맞춤 공고',
            trailing: widget.onShowAll == null ? null : _ShowAll(label: '전체 보기', onTap: widget.onShowAll!),
          ),
          const SizedBox(height: 12),
          rows([for (final r in home.later) line(r, dated: false)]),
        ],
        for (final (i, s) in home.changed.indexed) ...[
          SizedBox(height: i == 0 ? 28 : 8),
          _ChangedCard(entry: s, onTap: () => _openNotice(s.notice, null)),
        ],
      ],
    );
  }
}

class _ShowAll extends StatelessWidget {
  const _ShowAll({required this.label, required this.onTap});

  final String label;
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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [Text(label), const Icon(Icons.chevron_right_rounded, size: 18)],
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
          Text('현재 마감이 가까운 순으로 표시합니다', style: TextStyle(fontSize: 14, color: c.sub)),
          if (onOpenProfile != null) ...[
            const SizedBox(height: 12),
            SoftButton(label: '프로필 입력', onPressed: onOpenProfile!),
          ],
        ],
      ),
    );
  }
}

/// 오늘의 귀띔 말풍선 (D-050): `hero` 면 한 줄에 달라진 것의 건수만. '오늘 마감 2건 · 새 공고 1건 >'.
/// 공고 제목·라임·버튼·움직임은 두지 않는다. 누르면 브리핑이 도착 장면 없이 열린다.
class _Nudge extends StatelessWidget {
  const _Nudge({required this.nudge, required this.onOpen});

  final HomeNudge nudge;
  final VoidCallback onOpen;

  static const _noBreak = '\u00A0';

  /// 안내 말풍선(`TipBubble`)과 같은 모양. 꼬리는 왼쪽 아래.
  static const _radius = BorderRadius.only(
    topLeft: Radius.circular(22),
    topRight: Radius.circular(22),
    bottomRight: Radius.circular(22),
    bottomLeft: Radius.circular(6),
  );

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final parts = [
      if (nudge.dueToday > 0) (name: '오늘 마감', count: nudge.dueToday, color: c.heroUrgent),
      if (nudge.changed > 0) (name: '마감 변경', count: nudge.changed, color: c.loginInk),
      if (nudge.fresh > 0) (name: '새 공고', count: nudge.fresh, color: c.loginInk),
    ];
    return Semantics(
      label: ['오늘의 귀띔', for (final p in parts) '${p.name} ${p.count}건', '브리핑 열기'].join(', '),
      button: true,
      onTap: onOpen,
      excludeSemantics: true,
      child: Material(
        color: c.hero,
        borderRadius: _radius,
        child: InkWell(
          borderRadius: _radius,
          onTap: onOpen,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          for (final (i, p) in parts.indexed) ...[
                            // '오늘 마감 2건'은 한 덩어리로: 이름과 건수 사이는 줄바꿈 없는 공백이라 덩어리 앞에서만 줄이 바뀐다.
                            TextSpan(text: '${keepTogether(p.name)}$_noBreak'),
                            TextSpan(
                              text: keepTogether('${p.count}건'),
                              style: TextStyle(fontWeight: FontWeight.w700, color: p.color),
                            ),
                            // 가운뎃점은 앞 덩어리 뒤에 붙인다: 줄이 바뀌어도 다음 줄 맨 앞에 오지 않는다.
                            if (i < parts.length - 1) const TextSpan(text: '$_noBreak· '),
                          ],
                        ],
                      ),
                      style: TextStyle(fontSize: 15, height: 1.4, fontWeight: FontWeight.w600, color: c.loginInk),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right_rounded, size: 20, color: c.loginSub),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 홈 목록 줄 (D-050). 누르면 공고 리포트가 열린다.
/// [dated]면 마감 줄(이번 주 마감·다음 마감): 왼쪽 날짜 블록, 제목 위 표시, 메타 'D-N · 분류 · 변경 문구 또는 추천 이유'.
/// 아니면 아이콘 줄(새 공고·마감이 먼 맞춤 공고): 왼쪽 분류 아이콘, 메타 '마감 표기 · 변경 문구 또는 추천 이유'.
class _HomeLine extends StatelessWidget {
  const _HomeLine({
    required this.row,
    required this.category,
    required this.today,
    required this.personalized,
    required this.dated,
    required this.onTap,
  });

  final HomeRow row;
  final String category;
  final DateTime today;
  final bool personalized;
  final bool dated;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final n = row.notice;
    // 조건 상태 원. 최신 모드(비교할 프로필 없음)와 추천 정보가 없는 저장 공고에는 두지 않는다.
    final status = personalized ? row.recommendation?.eligibilityStatus : null;
    final marks = [
      if (dated) ...[
        if (row.majorPick) const MajorPickLabel(),
        if (row.saved != null) const Pill('저장한 공고', tone: PillTone.neutral),
        if (row.fresh) const Pill('새 공고', tone: PillTone.neutral),
      ],
    ];
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            dated ? _dateBlock(c, n) : _categoryIcon(c, n),
            const SizedBox(width: 12),
            // 위에서부터 표시(전체 폭) → 제목 줄(제목 + 상태 원) → 메타(전체 폭). 상태 원은 제목 옆에만 둔다.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (marks.isNotEmpty) ...[
                    Wrap(spacing: 6, runSpacing: 4, children: marks),
                    const SizedBox(height: 6),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          keepTitle(n.title),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.body, height: 1.4),
                        ),
                      ),
                      if (status != null) ...[const SizedBox(width: 8), EligibilityDot(status)],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text.rich(
                    TextSpan(children: dated ? _datedMeta(c, n) : _iconMeta(c, n)),
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

  /// 날짜 블록 (D-049): 큰 날짜와 요일(2주 안이라 월은 두지 않는다). 7일 안이면 빨강.
  /// 줄 글자에 D-day가 있어 화면 읽기에서는 뺀다.
  Widget _dateBlock(GwColors c, NoticeSummary n) {
    final day = n.applicationDeadline!.day;
    final urgent = daysLeft(n, today)! <= urgentDays;
    return ExcludeSemantics(
      child: Container(
        width: 44,
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(color: urgent ? c.urgentSoft : c.neutral, borderRadius: BorderRadius.circular(12)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${day.day}',
              style: TextStyle(
                fontSize: 19,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: urgent ? c.urgent : c.ink,
              ),
            ),
            Text(
              weekdayName(day),
              style: TextStyle(
                fontSize: 11,
                height: 1.3,
                fontWeight: FontWeight.w600,
                color: urgent ? c.urgent : c.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 분류 아이콘(가이드 §3). 알림톡 공고는 공고 카드와 같은 말풍선 아이콘.
  Widget _categoryIcon(GwColors c, NoticeSummary n) => SizedBox(
    width: 44,
    child: Center(
      child: n.isKakao
          ? GwIcon(GwGlyph.today, size: 26, color: c.muted, semanticLabel: '카카오톡 알림톡')
          : Icon(categoryIcon(n.category), size: 26, color: c.category(n.category), semanticLabel: category),
    ),
  );

  String get _reason => homeReason(row.recommendation, personalized: personalized);

  /// 메타의 라벨 앞 가운뎃점. 가운뎃점을 라벨에 붙여 줄이 바뀌면 가운뎃점 앞에서 바뀐다(줄 끝에 홀로 남지 않음).
  static String _then(String label) => ' ·\u00A0${keepTogether(label)}';

  /// 메타 마지막: 저장 후 마감 변경 문구가 추천 이유보다 앞선다(마감 줄·아이콘 줄 공통).
  List<InlineSpan> _last(GwColors c) {
    if (row.deadlineChanged) {
      return [
        TextSpan(
          text: _then(deadlineChangeText(row.saved!)),
          style: TextStyle(fontWeight: FontWeight.w600, color: c.sub),
        ),
      ];
    }
    final reason = _reason;
    return [
      if (reason.isNotEmpty)
        TextSpan(
          text: _then(reason),
          style: TextStyle(fontWeight: FontWeight.w500, color: c.accent),
        ),
    ];
  }

  /// 'D-3 · 17:00 마감 · 공모전 · 관심 분야'. 마지막은 저장 후 마감 변경 문구가 이유보다 앞선다.
  /// 큰 글자에서 줄이 넘어가도 '마감 3일 연/장'처럼 라벨 중간에서 끊기지 않게 한다.
  List<InlineSpan> _datedMeta(GwColors c, NoticeSummary n) {
    final deadline = n.applicationDeadline!;
    final left = daysLeft(n, today)!;
    return [
      TextSpan(
        text: keepTogether(left == 0 ? '오늘 마감' : 'D-$left') + (deadline.hasTime ? _then('${deadline.time} 마감') : ''),
        style: TextStyle(fontWeight: FontWeight.w600, color: left <= urgentDays ? c.urgent : c.sub),
      ),
      TextSpan(text: _then(category)),
      ..._last(c),
    ];
  }

  /// 공고 카드 첫 줄과 같은 마감 표기('12월 20일 마감 · D-27', 마감일이 없으면 '마감일 없음' 또는 원문 설명)
  /// · 변경 문구 또는 추천 이유(마감 줄과 같은 규칙).
  List<InlineSpan> _iconMeta(GwColors c, NoticeSummary n) {
    final deadline = n.applicationDeadline;
    final left = daysLeft(n, today);
    final soon = left != null && left <= urgentDays;
    return [
      if (deadline != null) ...[
        TextSpan(
          text: '${deadline.day.month}월 ${deadline.day.day}일${deadline.hasTime ? ' ${deadline.time}' : ''} 마감',
          style: TextStyle(fontWeight: FontWeight.w600, color: soon ? c.urgent : c.sub),
        ),
        if (left != null) TextSpan(text: _then(left == 0 ? '오늘' : 'D-$left')),
      ] else
        TextSpan(text: keepAll(n.deadlineNote ?? '마감일 없음')),
      ..._last(c),
    ];
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
                      keepTitle('${entry.notice.title}${now == null ? '' : ' · 이제 ${shortDate(now)}까지'}'),
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
