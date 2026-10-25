import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repository.dart';
import 'briefing_data.dart';
import 'common.dart';
import 'components.dart';
import 'format.dart';
import 'report_screen.dart';
import 'skeleton.dart';
import 'theme.dart';

/// 공고 탭: 홈의 '나에게 맞는 공고' 전체 목록 (2026-10-25 팀장 결정 Q1 B). 검색·필터 같은 새 기능은 없다.
/// 순서는 서버가 정한 그대로다.
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

  DateTime get _today => widget.today ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    reload();
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
    } catch (e) {
      if (!mounted) return;
      if (_list != null) {
        showRefreshFailed(context, e);
      } else {
        setState(() => _error = e);
      }
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
    return RefreshIndicator(
      onRefresh: reload,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: ScreenHeader(list.personalized ? '나에게 맞는 공고' : '최신 공고', trailing: list.personalized ? '추천순' : '최신순'),
          ),
          if (list.items.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: MessageView(title: '지금 보여드릴 공고가 없어요', detail: '학교 공지를 다시 확인하면 여기에 모여요.'),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
              sliver: SliverList.separated(
                itemCount: list.items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final e = list.items[i];
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
        : (status == 'met' ? null : Pill(status == 'not_met' ? '조건 불충족' : '확인 필요', tone: PillTone.neutral));
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
            n.title,
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
            Text(n.deadlineNote ?? '마감일이 공고에 나와 있지 않아요', style: TextStyle(fontSize: 14, color: c.sub)),
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
                            text: '${reason.isEmpty ? '' : ' · '}${status == 'not_met' ? '조건 불충족' : '조건 확인 필요'}',
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
