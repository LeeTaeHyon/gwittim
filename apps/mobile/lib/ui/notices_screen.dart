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
/// 제목 아래에 검색·분류 칩 줄을 늘 둔다 (D-026). 끌어내리면 새로 고침만 한다.
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
  final _queryFocus = FocusNode();

  /// 칩 줄 자리에 검색 칸을 연 상태
  bool _typing = false;

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
    _queryFocus.dispose();
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

  void _onQueryChanged(String value) {
    _query = value;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _search);
    setState(() {});
  }

  void _openSearch() {
    setState(() => _typing = true);
    _queryFocus.requestFocus();
  }

  void _closeSearch() {
    _queryField.clear();
    _queryFocus.unfocus();
    setState(() {
      _typing = false;
      _query = '';
    });
    _search();
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
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: ScreenHeader(
              list.personalized ? '나에게 맞는 공고' : '최신 공고',
              trailing: !_filtering ? (list.personalized ? '추천순' : '최신순') : (_searching ? '찾는 중' : '${items.length}건'),
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 52,
              child: _typing
                  ? _SearchRow(
                      controller: _queryField,
                      focus: _queryFocus,
                      onChanged: _onQueryChanged,
                      onSubmitted: (_) => _search(),
                      onClose: _closeSearch,
                    )
                  : _ChipRow(
                      // 행정 공지는 추천에 나오지 않는다
                      categories: {
                        for (final MapEntry(:key, :value) in _categories.entries)
                          if (key != 'admin_notice') key: value,
                      },
                      selected: _category,
                      query: _query,
                      onSearch: _openSearch,
                      onSelect: _onCategory,
                    ),
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
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
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

/// 카드 모양 칩 (D-026): 공고 카드처럼 `card` 바탕의 둥근 사각형. 고르면 `cta` 면 + `onCta` 글자
class _CardChip extends StatelessWidget {
  const _CardChip({required this.label, required this.on, required this.onTap, this.icon});

  final String label;
  final bool on;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final color = on ? c.onCta : c.body;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        button: true,
        selected: on,
        child: Material(
          color: on ? c.cta : c.card,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[Icon(icon, size: 18, color: color), const SizedBox(width: 6)],
                  Text(
                    label,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 제목 아래 칩 줄: 검색 + 전체 + 분류. 옆으로 넘긴다.
class _ChipRow extends StatelessWidget {
  const _ChipRow({
    required this.categories,
    required this.selected,
    required this.query,
    required this.onSearch,
    required this.onSelect,
  });

  final Map<String, String> categories;
  final String? selected;
  final String query;
  final VoidCallback onSearch;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _CardChip(
            label: query.trim().isEmpty ? '검색' : query.trim(),
            icon: Icons.search_rounded,
            on: query.trim().isNotEmpty,
            onTap: onSearch,
          ),
          _CardChip(label: '전체', on: selected == null, onTap: () => onSelect(null)),
          for (final MapEntry(:key, :value) in categories.entries)
            _CardChip(label: value, on: selected == key, onTap: () => onSelect(key)),
        ],
      ),
    );
  }
}

/// 검색 칩을 누르면 칩 줄 자리에 뜨는 검색 칸. 닫으면 검색어를 지우고 칩 줄로 돌아간다.
class _SearchRow extends StatelessWidget {
  const _SearchRow({
    required this.controller,
    required this.focus,
    required this.onChanged,
    required this.onSubmitted,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focus,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              textInputAction: TextInputAction.search,
              style: TextStyle(fontSize: 15, color: c.ink),
              decoration: InputDecoration(
                hintText: '공고 제목·내용 검색',
                hintStyle: TextStyle(fontSize: 15, color: c.muted),
                prefixIcon: Icon(Icons.search_rounded, size: 20, color: c.muted),
                filled: true,
                fillColor: c.card,
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
          ),
          TextButton(onPressed: onClose, child: const Text('닫기')),
        ],
      ),
    );
  }
}

/// 추천 공고 카드 (2026-11-01 단순화). 자세한 내용은 눌러서 리포트로 본다.
/// - 첫 줄: 분류 · 마감(날짜와 D-day). 마감일이 없으면 '마감일 없음' 또는 원문 설명(선착순 등)
/// - 오른쪽 칩은 하나: 7일 안 마감이면 D-day, 아니면 조건 상태(리포트와 같은 색)
/// - 마지막 줄: 추천 이유만. 조건 상태는 칩에만 둔다(체크 표시를 이유 앞에 두면 관련도로 읽힌다)
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
    // 리포트 체크리스트 배지와 같은 연한 칩: 충족 네이비, 확인 필요 주황, 미충족 빨강 (2026-11-01 팀장 요청)
    final chip = soon
        ? ddayPill(n, today)
        : switch (status) {
            'met' => const Pill('조건 충족'),
            'not_met' => const Pill('조건 미충족', tone: PillTone.urgent),
            _ => const Pill('확인 필요', tone: PillTone.check),
          };
    final reason = r.reasonCodes.any(personalReasons.containsKey)
        ? r.reasonCodes.map(reasonText).firstWhere((t) => t.isNotEmpty, orElse: () => '')
        : '';
    final deadline = n.applicationDeadline;
    final meta = TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.muted);
    return GwCard(
      onTap: onTap,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: category),
                      const TextSpan(text: ' · '),
                      if (deadline != null) ...[
                        TextSpan(
                          // 한 줄에 들어가게 요일은 빼고(리포트에 있음), 시각은 남긴다
                          text:
                              '${deadline.day.month}월 ${deadline.day.day}일${deadline.hasTime ? ' ${deadline.time}' : ''} 마감',
                          style: TextStyle(fontWeight: FontWeight.w600, color: soon ? c.urgent : c.body),
                        ),
                        if (left != null && !soon) TextSpan(text: ' · ${left == 0 ? '오늘' : 'D-$left'}'),
                      ] else
                        TextSpan(text: n.deadlineNote ?? '마감일 없음'),
                    ],
                  ),
                  style: meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              ?chip,
            ],
          ),
          const SizedBox(height: 6),
          Text(
            keepAll(n.title),
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: c.ink, height: 1.45),
          ),
          if (reason.isNotEmpty || (soon && status != 'met')) ...[
            const SizedBox(height: 6),
            Text.rich(
              TextSpan(
                children: [
                  if (reason.isNotEmpty)
                    TextSpan(
                      text: reason,
                      style: TextStyle(fontWeight: FontWeight.w500, color: c.accent),
                    ),
                  // 칩 자리를 D-day가 차지하면 조건 상태는 여기에 둔다.
                  if (soon && status != 'met')
                    TextSpan(
                      text: '${reason.isEmpty ? '' : ' · '}${status == 'not_met' ? '조건 미충족' : '조건 확인 필요'}',
                      style: TextStyle(color: c.muted),
                    ),
                ],
              ),
              style: const TextStyle(fontSize: 14),
            ),
          ],
        ],
      ),
    );
  }
}
