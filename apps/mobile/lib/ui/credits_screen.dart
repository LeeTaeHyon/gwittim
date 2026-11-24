import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repository.dart';
import 'agent_data.dart';
import 'agent_flow.dart';
import 'common.dart';
import 'components.dart';
import 'format.dart';
import 'skeleton.dart';
import 'theme.dart';

/// 크레딧 페이지 (docs/agent-privacy-spec.md §10.2): 보유, 다음 충전, 사용 규칙, 사용 내역(최근 90일).
/// 앱은 읽기만 한다. 광고·유료 충전 버튼은 두지 않는다 (D-039).
class CreditsScreen extends StatefulWidget {
  const CreditsScreen({super.key, required this.repository});

  final NoticeRepository repository;

  @override
  State<CreditsScreen> createState() => _CreditsScreenState();
}

class _CreditsData {
  const _CreditsData(this.credits, this.titles);

  final Credits credits;

  /// 공고 id → 제목. 찾지 못한 공고는 null
  final Map<String, String?> titles;
}

/// 제목을 찾지 못한 상세 분석 줄에 보이는 말
const _unknownNotice = '공고를 찾을 수 없음';

class _CreditsScreenState extends State<CreditsScreen> {
  late Future<_CreditsData> _future = _load();

  /// 눌러 보니 저장본이 없던 분석 (보관 기간이 지났거나 동의 철회로 삭제됨)
  final Set<String> _gone = {};

  Future<_CreditsData> _load() async {
    final credits = await widget.repository.getCredits();
    final refs = {
      for (final e in credits.entries)
        if (e.kind == 'detail_analysis') ?e.ref,
    };
    final titles = <String, String?>{};
    await Future.wait([
      for (final ref in refs)
        () async {
          try {
            titles[ref] = (await widget.repository.getNotice(ref))?.summary.title;
          } catch (_) {
            titles[ref] = null; // 제목을 못 읽어도 내역은 보인다
          }
        }(),
    ]);
    return _CreditsData(credits, titles);
  }

  /// 상세 분석 줄: 그 공고의 받은 분석으로 간다. 저장본이 없으면 삭제된 분석 문구를 보인다.
  Future<void> _open(CreditEntry entry, String? title) async {
    final ref = entry.ref;
    if (ref == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final response = await widget.repository.getAnalysis(ref);
      if (!mounted) return;
      if (response == null) {
        setState(() => _gone.add(ref));
        return;
      }
      await Navigator.of(context)
          .push(gwRoute(context, (_) => AnalysisReportScreen(response: response, title: title, receivedAt: entry.at)));
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(keepAll(errorMessage(e)))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const GwTopBar(title: '크레딧'),
      body: FutureBuilder(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) return const _CreditsSkeleton();
          if (snapshot.hasError) {
            return MessageView.error(snapshot.error!, onRetry: () => setState(() => _future = _load()));
          }
          return _body(snapshot.data!);
        },
      ),
    );
  }

  Widget _body(_CreditsData data) {
    final c = context.gw;
    final credits = data.credits;
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        const ScreenHeader('크레딧'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _Balance(credits: credits),
        ),
        Container(
          margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            color: c.summary,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(22),
              topRight: Radius.circular(22),
              bottomRight: Radius.circular(22),
              bottomLeft: Radius.circular(6),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '사용 규칙',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.ink),
              ),
              const SizedBox(height: 8),
              for (final rule in const ['매일 1개 충전, 최대 5개', '상세 분석 1개', '외부 공고 찾기 2개', '받은 분석 다시 보기 무료'])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 4,
                        height: 4,
                        margin: const EdgeInsets.only(top: 11, right: 10, left: 2),
                        decoration: BoxDecoration(color: c.muted, shape: BoxShape.circle),
                      ),
                      Expanded(
                        child: Text(rule, style: TextStyle(fontSize: 14, height: 1.6, color: c.body)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(26, 28, 26, 12),
          child: SectionTitle('사용 내역', trailing: Text('최근 90일', style: captionStyle(context))),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
            decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(20)),
            child: credits.entries.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Text('사용 내역이 없습니다.', style: TextStyle(fontSize: 15, color: c.muted)),
                  )
                : Column(
                    children: [
                      for (final (i, e) in credits.entries.indexed)
                        _EntryRow(
                          entry: e,
                          title: e.ref == null ? null : data.titles[e.ref],
                          gone: e.ref != null && e.kind == 'detail_analysis' && _gone.contains(e.ref),
                          last: i == credits.entries.length - 1,
                          onTap: e.kind == 'detail_analysis' && e.ref != null
                              ? () => _open(e, data.titles[e.ref])
                              : null,
                        ),
                    ],
                  ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(26, 12, 26, 0),
          child: Text(keepAll('실패해서 차감하지 않은 요청은 내역에 없습니다. 광고·유료 충전은 제공하지 않습니다.'), style: captionStyle(context)),
        ),
      ],
    );
  }
}

/// 보유 `n / 5`와 다음 충전. 채운 칸은 라임 면으로만 칠하고 글자에는 쓰지 않는다.
class _Balance extends StatelessWidget {
  const _Balance({required this.credits});

  final Credits credits;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final full = credits.balance >= Credits.max;
    return Semantics(
      container: true,
      label: '보유 크레딧 ${credits.balance} / ${Credits.max}. ${nextRefillText(credits)}',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
          decoration: BoxDecoration(color: c.hero, borderRadius: Gw.bubble),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '보유 크레딧',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.loginSub),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '${credits.balance} / ${Credits.max}',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                        color: c.loginInk,
                      ),
                    ),
                    if (full) ...[
                      const SizedBox(width: 6),
                      Text(
                        '최대 보유',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.loginSub),
                      ),
                    ],
                  ],
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < Credits.max; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        height: 40,
                        decoration: BoxDecoration(
                          color: i < credits.balance ? c.lime : c.loginInk.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(Icons.schedule_rounded, size: 18, color: c.loginSub),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      keepAll(nextRefillText(credits)),
                      style: TextStyle(fontSize: 14, height: 1.45, fontWeight: FontWeight.w600, color: c.loginInk),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.title,
    required this.gone,
    required this.last,
    required this.onTap,
  });

  final CreditEntry entry;

  /// 상세 분석의 공고 제목. 찾지 못했으면 null
  final String? title;

  /// 눌러 보니 저장본이 없는 분석
  final bool gone;
  final bool last;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final charge = entry.amount > 0;
    final amount = '${charge ? '+' : '−'}${entry.amount.abs()}';
    final label = switch (entry.kind) {
      'signup' => '가입 선물',
      'daily' => '매일 충전',
      'detail_analysis' => '상세 분석',
      'external_search' => '외부 공고 찾기',
      _ => '크레딧 변동',
    };
    final titleStyle = TextStyle(fontSize: 15, height: 1.45, fontWeight: FontWeight.w600, color: c.ink);
    final row = Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Text(
              amount,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: charge ? c.accent : c.ink),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                entry.kind == 'detail_analysis'
                    ? Text.rich(
                        TextSpan(
                          style: titleStyle,
                          children: [
                            TextSpan(text: label),
                            TextSpan(
                              text: keepTitle(' · ${title ?? _unknownNotice}'),
                              style: TextStyle(fontWeight: FontWeight.w500, color: c.sub),
                            ),
                          ],
                        ),
                      )
                    : Text(label, style: titleStyle),
                const SizedBox(height: 2),
                Text(shortDateTime(entry.at), style: captionStyle(context)),
                if (gone)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Semantics(
                      liveRegion: true,
                      child: Text('보관 기간이 지나 삭제된 분석입니다.', style: TextStyle(fontSize: 13, color: c.check)),
                    ),
                  ),
              ],
            ),
          ),
          if (onTap != null)
            Icon(Icons.chevron_right_rounded, size: 20, color: gone ? c.faint.withValues(alpha: 0.5) : c.faint),
        ],
      ),
    );
    if (onTap == null) return MergeSemantics(child: row);
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(12), child: row);
  }
}

class _CreditsSkeleton extends StatelessWidget {
  const _CreditsSkeleton();

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return GwSkeleton(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          const SizedBox(height: 64),
          Container(
            height: 150,
            decoration: BoxDecoration(color: c.card, borderRadius: Gw.bubble),
          ),
          const SizedBox(height: 14),
          Container(
            height: 120,
            decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(22)),
          ),
          const SizedBox(height: 28),
          for (var i = 0; i < 3; i++) ...[
            Container(
              height: 64,
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(20)),
            ),
          ],
        ],
      ),
    );
  }
}
