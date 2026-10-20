import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repository.dart';
import 'briefing_data.dart';
import 'common.dart';
import 'components.dart';
import 'format.dart';
import 'theme.dart';

/// 체크리스트 한 줄의 상태
enum CheckState { met, notMet, check, info }

class CheckRow {
  const CheckRow(this.state, this.label, {this.evidence, this.note});

  final CheckState state;
  final String label;

  /// 공고 원문 근거 (형광펜으로 표시)
  final String? evidence;

  /// 그 줄 아래 안내 말풍선
  final String? note;
}

final _privateCondition = RegExp(r'평점|학점|성적|소득|연령|나이');

/// 지원 전 체크리스트 (D-009). 판정은 서버의 condition_results를 그대로 쓰고, 앱은 다시 판정하지 않는다.
/// 추천을 거치지 않고 들어오면(저장 목록) 판정 없이 공고 조건과 근거만 보인다.
List<CheckRow> checklistRows(
  Notice notice,
  Recommendation? recommendation,
  String? Function(String field) profileValue,
) {
  final elig = notice.eligibility;
  final rows = <CheckRow>[];
  final results = recommendation?.conditionResults ?? const <ConditionResult>[];
  if (results.isNotEmpty) {
    for (final c in results) {
      final field = conditionFieldLabel(c.field);
      final value = profileValue(c.field);
      rows.add(switch (c.status) {
        'met' => CheckRow(CheckState.met, value == null ? field : '$field · $value', evidence: c.evidence),
        'not_met' => CheckRow(CheckState.notMet, '$field · 맞지 않아요', evidence: c.evidence),
        _ when c.unknownReason == 'profile_missing' => CheckRow(
          CheckState.check,
          '$field · 프로필에 없어요',
          evidence: c.evidence,
          note: '프로필에 입력하면 자동으로 비교해 드려요.',
        ),
        _ => CheckRow(CheckState.check, '$field · 직접 확인', evidence: c.evidence),
      });
    }
  } else {
    for (final c in elig.conditions) {
      rows.add(CheckRow(CheckState.info, conditionFieldLabel(c.field), evidence: c.evidence));
    }
  }
  for (final u in elig.unresolvedEvidence) {
    rows.add(
      CheckRow(
        CheckState.check,
        '직접 확인',
        evidence: u,
        note: _privateCondition.hasMatch(u)
            ? '귀띔은 성적을 받지 않아요. 이 조건은 학교 공지에서 직접 확인해 주세요.'
            : '자동으로 비교하지 못했어요. 학교 공지에서 확인해 주세요.',
      ),
    );
  }
  if (elig.conditions.isEmpty && elig.unresolvedEvidence.isEmpty) {
    rows.add(
      elig.explicitlyUnrestricted
          ? CheckRow(CheckState.met, '누구나 지원할 수 있어요', evidence: elig.unrestrictedEvidence)
          : const CheckRow(CheckState.info, '공고에서 지원 조건을 찾지 못했어요', note: '조건이 없다는 뜻은 아니에요. 학교 공지를 확인해 주세요.'),
    );
  }
  return rows;
}

/// 추천 이유 문장 조각: (형광펜 낱말들, 2주 안 마감 여부)
(List<String>, bool) reasonParts(Recommendation? r) {
  final codes = r?.reasonCodes ?? const <String>[];
  return (
    [
      for (final e in personalReasons.entries)
        if (codes.contains(e.key)) e.value,
    ],
    codes.contains('deadline_timing'),
  );
}

/// 공고 리포트 (D-009). 기존 상세 화면을 대신한다.
class ReportScreen extends StatefulWidget {
  const ReportScreen({
    super.key,
    required this.repository,
    required this.noticeId,
    required this.openUrl,
    this.recommendation,
    this.today,
  });

  final NoticeRepository repository;
  final String noticeId;
  final OpenUrl openUrl;

  /// 추천 목록에서 들어오면 조건 판정과 추천 이유를 함께 보인다.
  final Recommendation? recommendation;
  final DateTime? today;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  late Future<Notice?> _future = widget.repository.getNotice(widget.noticeId);
  SavedEntry? _savedEntry;
  bool? _saved;
  UserProfile? _profile;
  Map<String, Map<String, String>> _names = const {};
  Map<String, String> _categories = const {};

  @override
  void initState() {
    super.initState();
    _loadExtras();
  }

  Future<void> _loadExtras() async {
    final repo = widget.repository;
    try {
      final saved = await repo.listSaved();
      final mine = saved.where((e) => e.notice.noticeId == widget.noticeId);
      if (mounted) {
        setState(() {
          _saved = mine.isNotEmpty;
          _savedEntry = mine.firstOrNull;
        });
      }
    } catch (_) {
      // 저장 상태를 못 읽어도 리포트는 보여준다.
    }
    try {
      final profile = await repo.getProfile();
      final names = {
        for (final d in const ['majors', 'universities']) d: {for (final i in await repo.dictionary(d)) i.id: i.name},
      };
      final categories = await repo.categoryNames();
      if (mounted) {
        setState(() {
          _profile = profile;
          _names = names;
          _categories = categories;
        });
      }
    } catch (_) {
      // 체크리스트에 내 정보 이름만 빠진다.
    }
  }

  String? _profileValue(String field) {
    final p = _profile;
    if (p == null) return null;
    return switch (field) {
      'university_id' => p.universityId == null ? null : _names['universities']?[p.universityId] ?? p.universityId,
      'major_id' => p.majorId == null ? null : _names['majors']?[p.majorId] ?? p.majorId,
      'grade' => p.grade == null ? null : '${p.grade}학년',
      'enrollment_status' => switch (p.enrollmentStatus) {
        'enrolled' => '재학',
        'on_leave' => '휴학',
        'graduated' => '졸업',
        _ => null,
      },
      _ => null,
    };
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
      backgroundColor: Colors.white,
      appBar: AppBar(backgroundColor: Colors.white),
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
          return _body(notice);
        },
      ),
    );
  }

  Widget _body(Notice notice) {
    final n = notice.summary;
    final today = widget.today ?? DateTime.now();
    final rec = widget.recommendation;
    final changed = _savedEntry != null && _savedEntry!.deadlineChanged ? _savedEntry : null;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        Pill(_categories[n.category] ?? n.category, background: Gw.bg, foreground: Gw.sub),
                        _statusPill(n, today),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      n.title,
                      style: const TextStyle(fontSize: 24, height: 1.42, fontWeight: FontWeight.w700, color: Gw.ink),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      ['명지전문대 공지사항', if (n.published != null) '${shortDate(n.published!)} 게시'].join(' · '),
                      style: const TextStyle(fontSize: 14, color: Gw.muted),
                    ),
                  ],
                ),
              ),
              if (notice.description != null) _SummaryBubble(text: notice.description!),
              if (changed != null) _ChangeBanner(entry: changed),
              _Checklist(
                rows: checklistRows(notice, rec, _profileValue),
                status: rec?.eligibilityStatus,
                notice: notice,
              ),
              if (rec != null) _Reasons(recommendation: rec),
              _Schedule(notice: notice, today: today),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Row(
              children: [
                if (_saved != null) ...[
                  SizedBox(
                    width: 56,
                    height: 56,
                    child: IconButton(
                      tooltip: _saved! ? '저장 취소' : '저장',
                      style: IconButton.styleFrom(backgroundColor: Gw.navySoft, foregroundColor: Gw.navy),
                      icon: Icon(_saved! ? Icons.bookmark : Icons.bookmark_border),
                      onPressed: _toggleSave,
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _open(notice),
                    iconAlignment: IconAlignment.end,
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(rec?.eligibilityStatus == 'needs_check' ? '학교 공지에서 확인하기' : '학교 공지에서 보기'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _statusPill(NoticeSummary n, DateTime today) {
    if (n.lifecycleStatus != 'open') {
      return Pill(lifecycleLabel(n.lifecycleStatus), background: Gw.bg, foreground: Gw.sub);
    }
    final left = daysLeft(n, today);
    if (left == null) return const Pill('모집 중');
    final label = '모집 중 · ${left == 0 ? '오늘 마감' : 'D-$left'}';
    return left <= urgentDays ? Pill(label, background: Gw.urgentSoft, foreground: Gw.urgent) : Pill(label);
  }
}

class _SummaryBubble extends StatelessWidget {
  const _SummaryBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 22, 20, 0),
      padding: const EdgeInsets.all(18),
      decoration: const BoxDecoration(
        color: Gw.summary,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(22),
          topRight: Radius.circular(22),
          bottomRight: Radius.circular(22),
          bottomLeft: Radius.circular(6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              GwBadge(small: true),
              SizedBox(width: 8),
              Text(
                '한 줄로 말하면',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Gw.sub),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            text,
            style: const TextStyle(fontSize: 16.5, height: 1.65, fontWeight: FontWeight.w500, color: Gw.body),
          ),
          const SizedBox(height: 8),
          const Text('학교 공지를 바탕으로 정리했어요', style: TextStyle(fontSize: 12.5, color: Gw.muted)),
        ],
      ),
    );
  }
}

class _ChangeBanner extends StatelessWidget {
  const _ChangeBanner({required this.entry});

  final SavedEntry entry;

  @override
  Widget build(BuildContext context) {
    final before = entry.saved.savedDeadlineSnapshot;
    final now = entry.notice.applicationDeadline;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(color: Gw.navySoft, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          const Icon(Icons.alarm, color: Gw.urgent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '저장한 뒤 ${deadlineChangeText(entry)}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Gw.body),
                ),
                Text(
                  '${before == null ? '미상' : shortDate(before)} → ${now == null ? '미상' : shortDate(now)}',
                  style: const TextStyle(fontSize: 13, color: Gw.sub),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Checklist extends StatelessWidget {
  const _Checklist({required this.rows, required this.status, required this.notice});

  final List<CheckRow> rows;
  final String? status;
  final Notice notice;

  @override
  Widget build(BuildContext context) {
    final badge = switch (status) {
      'met' => const Pill('조건 충족', background: Gw.navy, foreground: Colors.white),
      'needs_check' => const Pill('확인이 필요해요', background: Gw.checkSoft, foreground: Gw.check),
      'not_met' => const Pill('맞지 않아요', background: Gw.urgentSoft, foreground: Gw.urgent),
      _ => null,
    };
    final checks = rows.where((r) => r.state == CheckState.check).length;
    final mets = rows.where((r) => r.state == CheckState.met).length;
    final intro = status == null
        ? '공고에서 찾은 조건이에요.'
        : checks > 0
        ? (mets > 0 ? '조건 $mets개는 맞아요. $checks개는 직접 확인해 주세요.' : '$checks개 조건은 직접 확인해 주세요.')
        : '공고에서 찾은 조건을 내 프로필과 비교했어요.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 36, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle('지원 전 체크리스트', trailing: badge),
          const SizedBox(height: 8),
          Text(intro, style: const TextStyle(fontSize: 14, height: 1.55, color: Gw.sub)),
          const SizedBox(height: 8),
          for (final r in rows) _CheckLine(row: r),
          if (!notice.eligibility.extractionComplete)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('첨부파일·이미지에 조건이 더 있을 수 있어요. 지원 전에 원문을 확인해 주세요.', style: captionStyle),
            ),
        ],
      ),
    );
  }
}

class _CheckLine extends StatelessWidget {
  const _CheckLine({required this.row});

  final CheckRow row;

  @override
  Widget build(BuildContext context) {
    final check = row.state == CheckState.check;
    final box = switch (row.state) {
      CheckState.met => _box(Gw.navy, const Icon(Icons.check, size: 16, color: Gw.lime, semanticLabel: '충족')),
      CheckState.notMet => _box(
        Gw.urgent,
        const Icon(Icons.close, size: 16, color: Colors.white, semanticLabel: '맞지 않음'),
      ),
      CheckState.check => Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: const Color(0xFFFFF7EA),
          border: Border.all(color: Gw.checkLine, width: 2),
          borderRadius: BorderRadius.circular(7),
        ),
        child: const Icon(Icons.question_mark, size: 14, color: Gw.check, semanticLabel: '확인 필요'),
      ),
      CheckState.info => _box(Gw.bg, const Icon(Icons.remove, size: 16, color: Gw.sub, semanticLabel: '안내')),
    };
    const evidenceStyle = TextStyle(fontSize: 13.5, height: 1.5, color: Gw.sub);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              box,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.label,
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: check ? Gw.check : Gw.body),
                    ),
                    if (row.evidence != null) ...[
                      const SizedBox(height: 4),
                      // 근거가 길면 형광펜 없이 줄바꿈한다.
                      row.evidence!.length <= 24
                          ? Text.rich(
                              TextSpan(
                                style: evidenceStyle,
                                children: [
                                  const TextSpan(text: '공고 “'),
                                  markSpan(row.evidence!, evidenceStyle, color: check ? Gw.checkMark : Gw.lime),
                                  const TextSpan(text: '”'),
                                ],
                              ),
                            )
                          : Text('공고 “${row.evidence}”', style: evidenceStyle),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (row.note != null)
            Container(
              margin: const EdgeInsets.only(left: 36, top: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: const BoxDecoration(
                color: Gw.summary,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomRight: Radius.circular(18),
                  bottomLeft: Radius.circular(5),
                ),
              ),
              child: Text(row.note!, style: const TextStyle(fontSize: 13.5, height: 1.55, color: Gw.body)),
            ),
        ],
      ),
    );
  }

  Widget _box(Color color, Widget icon) => Container(
    width: 24,
    height: 24,
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(7)),
    child: icon,
  );
}

class _Reasons extends StatelessWidget {
  const _Reasons({required this.recommendation});

  final Recommendation recommendation;

  @override
  Widget build(BuildContext context) {
    final (words, soon) = reasonParts(recommendation);
    if (words.isEmpty && !soon) return const SizedBox.shrink();
    const style = TextStyle(fontSize: 16, height: 1.75, color: Gw.body);
    final spans = <InlineSpan>[];
    for (var i = 0; i < words.length; i++) {
      if (i > 0) spans.add(const TextSpan(text: ', '));
      spans.add(markSpan(words[i], style));
    }
    if (words.isNotEmpty) {
      // 받침 있는 '전공'은 '과', 나머지는 '와'
      spans.add(TextSpan(text: words.last == '전공' ? '과 관련 있' : '와 관련 있'));
      spans.add(TextSpan(text: soon ? '고 ' : '어요.'));
    }
    if (soon) spans.addAll([markSpan('2주 안에', style), const TextSpan(text: ' 마감돼요.')]);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 36, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle('이래서 추천했어요'),
          const SizedBox(height: 12),
          Text.rich(TextSpan(style: style, children: spans)),
          const SizedBox(height: 8),
          const Text('추천 순서를 정한 이유예요. 합격 가능성을 뜻하지 않아요.', style: captionStyle),
        ],
      ),
    );
  }
}

class _Schedule extends StatelessWidget {
  const _Schedule({required this.notice, required this.today});

  final Notice notice;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final n = notice.summary;
    final day = DateTime(today.year, today.month, today.day);
    final deadline = n.applicationDeadline;
    final left = daysLeft(n, today);
    final events = <(DateTime, _Event)>[
      if (n.published != null) (n.published!.day, _event(shortDate(n.published!), sub: '게시', dot: _Dot.past)),
      if (notice.applicationStart != null)
        (notice.applicationStart!.day, _event(shortDate(notice.applicationStart!), sub: '신청 시작', dot: _Dot.past)),
      (day, _event('${shortDay(day)} · 오늘', dot: _Dot.today, color: Gw.navy)),
      if (deadline != null)
        (
          deadline.day,
          _event(
            '${shortDate(deadline)} · 신청 마감',
            dot: (left ?? 99) <= urgentDays ? _Dot.urgent : _Dot.main,
            bold: true,
            lines: [
              if (left != null) (left == 0 ? '오늘 마감이에요' : '$left일 남았어요'),
              if (!deadline.hasTime) '마감 시각은 공고에 나와 있지 않아요',
              if (n.deadlineNote != null) n.deadlineNote!,
            ],
          ),
        ),
      if (notice.activityPeriod?.start case final s?) (s.day, _event(shortDate(s), sub: '활동 시작', dot: _Dot.past)),
      if (notice.activityPeriod?.end case final e?) (e.day, _event(shortDate(e), sub: '활동 끝', dot: _Dot.past)),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final stale = staleNotice(notice.lastVerifiedAt, DateTime.now().toUtc());
    final verified = notice.lastVerifiedAt?.toLocal();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 36, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle('일정'),
          const SizedBox(height: 16),
          for (var i = 0; i < events.length; i++) _TimelineItem(last: i == events.length - 1, child: events[i].$2),
          if (deadline == null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                n.deadlineNote ?? '마감일이 공고에 나와 있지 않아요. 학교 공지를 확인해 주세요.',
                style: const TextStyle(fontSize: 14, color: Gw.sub),
              ),
            ),
          const SizedBox(height: 20),
          if (stale != null)
            Text(stale, style: const TextStyle(fontSize: 13, color: Gw.urgent))
          else if (verified != null)
            Text(
              '${verified.month}월 ${verified.day}일 ${verified.hour.toString().padLeft(2, '0')}:${verified.minute.toString().padLeft(2, '0')} 기준이에요',
              style: captionStyle,
            ),
        ],
      ),
    );
  }

  _Event _event(
    String title, {
    String? sub,
    required _Dot dot,
    Color? color,
    bool bold = false,
    List<String> lines = const [],
  }) => _Event(title: title, sub: sub, dot: dot, color: color, bold: bold, lines: lines);
}

enum _Dot { past, today, main, urgent }

class _Event extends StatelessWidget {
  const _Event({
    required this.title,
    this.sub,
    required this.dot,
    this.color,
    this.bold = false,
    this.lines = const [],
  });

  final String title;
  final String? sub;
  final _Dot dot;
  final Color? color;
  final bool bold;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 15,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
            color: color ?? (bold ? Gw.ink : Gw.body),
          ),
        ),
        if (sub != null) Text(sub!, style: const TextStyle(fontSize: 13, color: Gw.muted)),
        for (final l in lines)
          Text(
            l,
            style: TextStyle(
              fontSize: 13,
              color: dot == _Dot.urgent && l.endsWith('남았어요') ? Gw.urgent : Gw.muted,
              fontWeight: dot == _Dot.urgent && l.endsWith('남았어요') ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
      ],
    );
  }
}

class _TimelineItem extends StatelessWidget {
  const _TimelineItem({required this.child, required this.last});

  final _Event child;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final dot = switch (child.dot) {
      _Dot.past => Container(
        width: 10,
        height: 10,
        margin: const EdgeInsets.only(top: 6),
        decoration: const BoxDecoration(color: Color(0xFFB3B8C8), shape: BoxShape.circle),
      ),
      _Dot.today => Container(
        width: 12,
        height: 12,
        margin: const EdgeInsets.only(top: 5),
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: Gw.navy, width: 3),
        ),
      ),
      _Dot.main => Container(
        width: 12,
        height: 12,
        margin: const EdgeInsets.only(top: 5),
        decoration: const BoxDecoration(color: Gw.navy, shape: BoxShape.circle),
      ),
      _Dot.urgent => Container(
        width: 12,
        height: 12,
        margin: const EdgeInsets.only(top: 5),
        decoration: const BoxDecoration(color: Gw.urgent, shape: BoxShape.circle),
      ),
    };
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 12,
            child: Column(
              children: [
                dot,
                if (!last)
                  Expanded(
                    child: Container(width: 2, margin: const EdgeInsets.only(top: 4), color: Gw.line),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 18),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}
