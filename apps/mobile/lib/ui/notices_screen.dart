import 'dart:async';

import 'package:flutter/material.dart';

import '../data/cached_repository.dart';
import '../data/models.dart';
import '../data/repository.dart';
import 'briefing_data.dart';
import 'common.dart';
import 'components.dart';
import 'format.dart';
import 'report_screen.dart';
import 'skeleton.dart';
import 'theme.dart';

/// 공고 탭: 홈의 '나에게 맞는 공고' 전체 목록 (2026-10-25 팀장 결정 Q1 B). 순서는 서버가 정한 추천순 그대로다.
///
/// 맨 위에 검색 칸과 분류 칩을 숨겨 둔다 (D-026). 목록을 조금 끌어내리면 나오고, 더 끌어내리면 새로 고침이다.
/// 검색어·분류를 고르면 서버가 추천 후보 전체에서 찾는다 (받아 둔 50건 안이 아니라).
class NoticesScreen extends StatefulWidget {
  const NoticesScreen({super.key, required this.repository, required this.openUrl, this.today});

  final NoticeRepository repository;
  final OpenUrl openUrl;
  final DateTime? today;

  @override
  State<NoticesScreen> createState() => NoticesScreenState();
}

class NoticesScreenState extends State<NoticesScreen> {
  RecommendationList? _list;
  Map<String, String> _categories = const {};
  Object? _error;

  /// 검색 결과. 검색어·분류가 없으면 null이고 [_list]를 보인다.
  RecommendationList? _results;
  String _query = '';
  String? _category;
  bool _searching = false;
  int _searchSeq = 0;
  Timer? _debounce;
  final _queryField = TextEditingController();
  final _scroll = ScrollController();
  final _panelKey = GlobalKey();
  bool _panelHidden = false;

  DateTime get _today => widget.today ?? DateTime.now();
  bool get _filtering => _query.trim().isNotEmpty || _category != null;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _queryField.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 당겨서 새로 고침: 탭끼리 나눠 쓰는 응답도 버리고 서버에서 다시 받는다.
  Future<void> refresh() {
    forgetCached(widget.repository);
    return reload();
  }

  /// 프로필을 저장하거나 당겨서 새로고침할 때. 받는 동안 보이는 목록은 그대로 둔다.
  Future<void> reload() async {
    try {
      final list = await widget.repository.listRecommendations();
      var categories = _categories;
      try {
        categories = await widget.repository.categoryNames();
      } catch (_) {
        // 분류 이름만 코드로 보인다.
      }
      if (!mounted) return;
      setState(() {
        _list = list;
        _categories = categories;
        _error = null;
      });
      _hidePanelOnce();
      if (_filtering) await _search();
    } catch (e) {
      if (!mounted) return;
      if (_list != null) {
        showRefreshFailed(context, e);
      } else {
        setState(() => _error = e);
      }
    }
  }

  /// 처음 목록을 그린 뒤 검색 칸·칩만큼 내려 둔다. 목록이 짧아 내릴 수 없으면 그대로 보인다.
  void _hidePanelOnce() {
    if (_panelHidden) return;
    _panelHidden = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final panel = _panelKey.currentContext?.size?.height;
      if (panel == null || !_scroll.hasClients || _filtering) return;
      if (_scroll.position.maxScrollExtent >= panel) _scroll.jumpTo(panel);
    });
  }

  void _onQueryChanged(String value) {
    _query = value;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _search);
    setState(() {});
  }

  void _onCategory(String? code) {
    if (code == _category) return;
    setState(() => _category = code);
    _search();
  }

  Future<void> _search() async {
    _debounce?.cancel();
    final seq = ++_searchSeq;
    if (!_filtering) {
      setState(() {
        _results = null;
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    try {
      final results = await widget.repository.searchNotices(query: _query, category: _category);
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } catch (e) {
      if (!mounted || seq != _searchSeq) return;
      setState(() => _searching = false);
      showRefreshFailed(context, e);
    }
  }

  Future<void> _open(RecommendationEntry e) async {
    await Navigator.of(context).push(
      gwRoute(
        context,
        (_) => ReportScreen(
          repository: widget.repository,
          noticeId: e.notice.noticeId,
          recommendation: e.recommendation,
          openUrl: widget.openUrl,
          today: widget.today,
        ),
      ),
    );
    reload();
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    if (list == null) {
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
    // 검색 결과를 받기 전에는 예전 목록을 그대로 두지 않고 비운다 (다른 조건의 공고가 섞여 보이지 않게).
    final items = !_filtering ? list.items : (_results?.items ?? const <RecommendationEntry>[]);
    return RefreshIndicator(
      onRefresh: refresh,
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: _SearchPanel(
              key: _panelKey,
              controller: _queryField,
              onChanged: _onQueryChanged,
              onSubmitted: (_) => _search(),
              onClear: () {
                _queryField.clear();
                _onQueryChanged('');
              },
              // 행정 공지는 추천에 나오지 않는다
              categories: {
                for (final MapEntry(:key, :value) in _categories.entries)
                  if (key != 'admin_notice') key: value,
              },
              selected: _category,
              onSelect: _onCategory,
            ),
          ),
          SliverToBoxAdapter(
            child: ScreenHeader(
              list.personalized ? '나에게 맞는 공고' : '최신 공고',
              trailing: !_filtering ? (list.personalized ? '추천순' : '최신순') : (_searching ? '찾는 중' : '${items.length}건'),
            ),
          ),
          if (items.isEmpty && !_searching)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _filtering
                  ? const MessageView(title: '찾는 공고가 없습니다', detail: '다른 검색어나 분류로 찾아 보세요.')
                  : const MessageView(title: '표시할 공고가 없습니다', detail: '학교 공지를 다시 확인하면 여기에 표시됩니다.'),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
              sliver: SliverList.separated(
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final e = items[i];
                  return NoticeCard(
                    entry: e,
                    category: _categories[e.notice.category] ?? e.notice.category,
                    today: _today,
                    onTap: () => _open(e),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// 숨겨 둔 검색 칸과 분류 칩 (D-026). 칩은 하나만 고르고, '전체'를 누르면 분류 없이 본다.
class _SearchPanel extends StatelessWidget {
  const _SearchPanel({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onSubmitted,
    required this.onClear,
    required this.categories,
    required this.selected,
    required this.onSelect,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;
  final Map<String, String> categories;
  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              textInputAction: TextInputAction.search,
              style: TextStyle(fontSize: 15, color: c.ink),
              decoration: InputDecoration(
                hintText: '공고 제목·내용 검색',
                hintStyle: TextStyle(fontSize: 15, color: c.muted),
                prefixIcon: Icon(Icons.search_rounded, color: c.muted),
                suffixIcon: controller.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '검색어 지우기',
                        icon: Icon(Icons.close_rounded, color: c.muted),
                        onPressed: onClear,
                      ),
                filled: true,
                fillColor: c.card, // 탭 바탕이 neutral이라 카드 색으로 띄운다
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _CategoryChip(label: '전체', on: selected == null, onTap: () => onSelect(null)),
                for (final MapEntry(:key, :value) in categories.entries)
                  _CategoryChip(label: value, on: selected == key, onTap: () => onSelect(key)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 하나 고르는 칩: 고르면 `cta` 면 + `onCta` 글자 (ui-style §5 세그먼트와 같은 표시)
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.label, required this.on, required this.onTap});

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        button: true,
        selected: on,
        child: Material(
          color: on ? c.cta : c.card,
          shape: StadiumBorder(side: BorderSide(color: on ? c.cta : c.line, width: 1.5)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Center(
                widthFactor: 1,
                child: Text(
                  label,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: on ? c.onCta : c.body),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 추천 공고 카드. 칩은 가장 중요한 하나만 둔다: 7일 안 마감이면 D-day, 아니면 조건 상태(확인 필요 등).
/// 분류는 제목 위 작은 글자, 조건 충족은 추천 이유 앞의 작은 체크로 보인다.
class NoticeCard extends StatelessWidget {
  const NoticeCard({super.key, required this.entry, required this.category, required this.today, required this.onTap});

  final RecommendationEntry entry;
  final String category;
  final DateTime today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final n = entry.notice;
    final r = entry.recommendation;
    final c = context.gw;
    final left = daysLeft(n, today);
    final soon = left != null && left <= urgentDays;
    final status = r.eligibilityStatus;
    // 확인 필요는 목록에서 회색으로 차분하게 보인다 (D-009).
    final chip = soon
        ? ddayPill(n, today)
        : (status == 'met' ? null : Pill(status == 'not_met' ? '조건 미충족' : '확인 필요', tone: PillTone.neutral));
    final reason = r.reasonCodes.any(personalReasons.containsKey)
        ? r.reasonCodes.map(reasonText).firstWhere((t) => t.isNotEmpty, orElse: () => '')
        : '';
    final deadline = n.applicationDeadline;
    final accent = TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.accent);
    final muted = TextStyle(fontSize: 14, color: c.muted);
    return GwCard(
      onTap: onTap,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  category,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.muted),
                ),
              ),
              ?chip,
            ],
          ),
          const SizedBox(height: 6),
          Text(
            keepAll(n.title),
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: c.ink, height: 1.45),
          ),
          const SizedBox(height: 6),
          if (deadline != null)
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${shortDate(deadline)} 마감',
                    style: TextStyle(fontWeight: FontWeight.w600, color: c.body),
                  ),
                  if (left != null && !soon) TextSpan(text: ' · ${left == 0 ? '오늘' : 'D-$left'}'),
                ],
              ),
              style: TextStyle(fontSize: 14, color: c.sub),
            )
          else
            Text(n.deadlineNote ?? '공고에 마감일 없음', style: TextStyle(fontSize: 14, color: c.sub)),
          if (status == 'met' || reason.isNotEmpty || (soon && status != 'met')) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                if (status == 'met') ...[
                  Icon(Icons.check_rounded, size: 16, color: c.accent, semanticLabel: '조건 충족'),
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        if (reason.isNotEmpty)
                          TextSpan(text: reason, style: accent)
                        else if (status == 'met')
                          TextSpan(text: '지원 조건 충족', style: accent),
                        // 칩 자리를 D-day가 차지하면 조건 상태는 여기에 둔다.
                        if (soon && status != 'met')
                          TextSpan(
                            text: '${reason.isEmpty ? '' : ' · '}${status == 'not_met' ? '조건 미충족' : '조건 확인 필요'}',
                            style: muted,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
