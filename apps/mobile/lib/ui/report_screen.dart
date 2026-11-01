import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repository.dart';
import 'briefing_data.dart';
import 'common.dart';
import 'components.dart';
import 'format.dart';
import 'icons.dart';
import 'skeleton.dart';
import 'theme.dart';

/// 수집 게시판 이름 (D-013). 서버 출처 설정(backend/sources.py)과 맞춘다.
const _sourceNames = {
  'mjc_www_notice': '명지전문대 공지사항',
  'mjc_www_scholarship': '명지전문대 장학공지',
  'mjc_www_job': '명지전문대 채용공지',
  'mjc_www_work': '명지전문대 근로게시판',
  'mjc_kakao': '명지전문대 카카오톡 알림톡', // D-019: 웹 원문 링크 없음
};

/// 체크리스트 한 줄의 상태
enum CheckState { met, notMet, check, info }

class CheckRow {
  const CheckRow(this.state, this.label, {this.field, this.evidence, this.note, this.moreEvidence = const []});

  final CheckState state;
  final String label;

  /// 조건 항목 이름표 ('학교', '학년' 등). 없으면 이름표 없이 label만.
  final String? field;

  /// 공고 원문 근거 (형광펜으로 표시)
  final String? evidence;

  /// 같은 종류로 묶인 나머지 근거 (groupCheckRows)
  final List<String> moreEvidence;

  /// 그 줄 아래 안내 말풍선
  final String? note;

  List<String> get evidences => [?evidence, ...moreEvidence];

  /// 이 줄이 나타내는 조건 수 (묶인 줄은 근거 수)
  int get count => evidences.length > 1 ? evidences.length : 1;
}

/// 이름표 없는 같은 종류 줄(상태·문구·안내가 같음)이 2개 이상이면 첫 자리에 한 줄로 묶는다.
/// 예: '직접 확인' 4개 → '직접 확인 4개' 한 줄에 근거 4개, 안내 말풍선 하나.
List<CheckRow> groupCheckRows(List<CheckRow> rows) {
  final groups = <(CheckState, String, String?), List<CheckRow>>{};
  for (final r in rows) {
    if (r.field == null && r.evidence != null) groups.putIfAbsent((r.state, r.label, r.note), () => []).add(r);
  }
  final out = <CheckRow>[];
  for (final r in rows) {
    final group = r.field == null && r.evidence != null ? groups[(r.state, r.label, r.note)]! : null;
    if (group == null || group.length < 2) {
      out.add(r);
    } else if (identical(group.first, r)) {
      out.add(
        CheckRow(
          r.state,
          '${r.label} ${group.length}개',
          evidence: r.evidence,
          moreEvidence: [for (final g in group.skip(1)) g.evidence!],
          note: r.note,
        ),
      );
    }
  }
  return out;
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
        'met' => CheckRow(CheckState.met, value ?? '충족', field: field, evidence: c.evidence),
        'not_met' => CheckRow(CheckState.notMet, '미충족', field: field, evidence: c.evidence),
        _ when c.unknownReason == 'profile_missing' => CheckRow(
          CheckState.check,
          '프로필 미입력',
          field: field,
          evidence: c.evidence,
          note: '프로필에 입력하면 자동으로 비교합니다.',
        ),
        _ => CheckRow(CheckState.check, '직접 확인', field: field, evidence: c.evidence),
      });
    }
  } else {
    for (final c in elig.conditions) {
      rows.add(CheckRow(CheckState.info, conditionFieldLabel(c.field), evidence: c.evidence));
    }
  }
  final preferred = elig.preferredEvidence.toSet();
  for (final u in elig.unresolvedEvidence) {
    if (preferred.contains(u)) continue;
    rows.add(
      CheckRow(
        CheckState.check,
        '직접 확인',
        evidence: u,
        note: _privateCondition.hasMatch(u)
            ? '귀띔은 성적을 받지 않습니다. 이 조건은 학교 공지에서 직접 확인해 주세요.'
            : '자동으로 비교하지 못했습니다. 학교 공지에서 확인해 주세요.',
      ),
    );
  }
  // 우대 사항은 지원 자격 뒤에, 확인 필요보다 약한 안내로 보인다 (D-015)
  for (final u in elig.unresolvedEvidence.where(preferred.contains)) {
    rows.add(CheckRow(CheckState.info, '우대 사항', evidence: u, note: '갖추면 유리한 조건입니다.'));
  }
  if (elig.conditions.isEmpty && elig.unresolvedEvidence.isEmpty) {
    rows.add(
      elig.explicitlyUnrestricted
          ? CheckRow(CheckState.met, '누구나 지원 가능', evidence: elig.unrestrictedEvidence)
          : const CheckRow(CheckState.info, '공고에서 지원 조건을 찾지 못했습니다', note: '조건이 없다는 뜻은 아닙니다. 학교 공지를 확인해 주세요.'),
    );
  }
  return groupCheckRows(rows);
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
      messenger.showSnackBar(SnackBar(content: Text(wasSaved ? '저장이 취소되었습니다.' : '공고가 저장되었습니다.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(e))));
    }
  }

  Future<void> _openRelated(String noticeId) => Navigator.of(context).push(
    gwRoute(
      context,
      (_) => ReportScreen(
        repository: widget.repository,
        noticeId: noticeId,
        openUrl: widget.openUrl,
        today: widget.today,
      ),
    ),
  );

  Future<void> _open(String url) async {
    final ok = await widget.openUrl(Uri.parse(url));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('원문을 열지 못했습니다.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // 스크롤하면 위 막대에 공고 제목이 나타난다.
    return FutureBuilder(
      future: _future,
      builder: (context, snapshot) => Scaffold(
        backgroundColor: context.gw.card,
        appBar: GwTopBar(title: snapshot.hasError ? null : snapshot.data?.summary.title),
        body: Builder(
          builder: (context) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const ReportSkeleton();
            }
            if (snapshot.hasError) {
              return MessageView.error(
                snapshot.error!,
                onRetry: () => setState(() {
                  _future = widget.repository.getNotice(widget.noticeId);
                }),
              );
            }
            final notice = snapshot.data;
            if (notice == null) {
              return const MessageView(title: '공고를 찾을 수 없습니다', detail: '학교 공지에서 삭제되었거나 아직 정리 중일 수 있습니다.');
            }
            return _body(notice);
          },
        ),
      ),
    );
  }

  Widget _body(Notice notice) {
    final n = notice.summary;
    final today = widget.today ?? DateTime.now();
    final rec = widget.recommendation;
    final changed = _savedEntry != null && _savedEntry!.deadlineChanged ? _savedEntry : null;
    final c = context.gw;
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
                        Pill(_categories[n.category] ?? n.category, tone: PillTone.neutral),
                        _statusPill(n, today),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      keepAll(n.title),
                      style: TextStyle(fontSize: 24, height: 1.42, fontWeight: FontWeight.w700, color: c.ink),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          _sourceNames[notice.sourceId] ?? '명지전문대 학교 공지',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.sub),
                        ),
                        if (n.published != null)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.calendar_today_rounded, size: 14, color: c.muted),
                              const SizedBox(width: 4),
                              Text(
                                '${shortDate(n.published!)} ${n.sourceUrl == null ? '발송' : '게시'}',
                                style: TextStyle(fontSize: 14, color: c.muted),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (notice.description != null) _SummaryBubble(text: notice.description!),
              // D-006: 원문 확인이 24시간을 넘으면 요약 바로 아래에 알린다. 원문은 아래 '학교 공지에서 보기'로 연다.
              // 알림톡은 보낸 뒤 바뀌지 않으므로 원문 재확인 안내를 하지 않는다 (D-019)
              if (n.sourceUrl != null)
                if (staleNotice(notice.lastVerifiedAt, DateTime.now().toUtc()) case final stale?) _StaleBox(text: stale),
              if (changed != null) _ChangeBanner(entry: changed),
              _Checklist(
                rows: checklistRows(notice, rec, _profileValue),
                status: rec?.eligibilityStatus,
                notice: notice,
              ),
              if (rec != null) _Reasons(recommendation: rec),
              _Schedule(notice: notice, today: today),
              if (notice.relatedNotices.isNotEmpty) _Related(notices: notice.relatedNotices, onOpen: _openRelated),
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
                      style: IconButton.styleFrom(backgroundColor: c.chip, foregroundColor: c.onChip),
                      icon: GwIcon(GwGlyph.saved, filled: _saved!, color: c.onChip),
                      onPressed: _toggleSave,
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: switch (notice.summary.sourceUrl) {
                    final url? => FilledButton.icon(
                      onPressed: () => _open(url),
                      iconAlignment: IconAlignment.end,
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: Text(rec?.eligibilityStatus == 'needs_check' ? '학교 공지에서 확인하기' : '학교 공지에서 보기'),
                    ),
                    // D-025: 알림톡 본문에 적힌 학교 사이트(스마트케어 등). 사이트는 수집하지 않고 열기만 한다
                    null when notice.applyUrl != null => FilledButton.icon(
                      onPressed: () => _open(notice.applyUrl!),
                      iconAlignment: IconAlignment.end,
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: const Text('신청 사이트 열기'),
                    ),
                    // D-019: 알림톡은 열 수 있는 웹 원문이 없다. 받은 카톡 메시지가 원문이다
                    null => Text(
                      keepAll('카카오톡 알림톡으로 받은 공지라 원문 링크가 없습니다.'),
                      textAlign: TextAlign.center,
                      style: captionStyle(context),
                    ),
                  },
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
      return Pill(lifecycleLabel(n.lifecycleStatus), tone: PillTone.neutral);
    }
    final left = daysLeft(n, today);
    if (left == null) return const Pill('모집 중');
    final label = '모집 중 · ${left == 0 ? '오늘 마감' : 'D-$left'}';
    return Pill(label, tone: left <= urgentDays ? PillTone.urgent : PillTone.chip);
  }
}

class _SummaryBubble extends StatelessWidget {
  const _SummaryBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 22, 20, 0),
      padding: const EdgeInsets.all(18),
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
          Row(
            children: [
              const GwBadge(small: true),
              const SizedBox(width: 8),
              Text(
                '한 줄로 말하면',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.sub),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            keepAll(text),
            style: TextStyle(fontSize: 16.5, height: 1.65, fontWeight: FontWeight.w500, color: c.body),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: c.card.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(10)),
              child: Text('학교 공지를 바탕으로 정리', style: TextStyle(fontSize: 12, color: c.muted)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 오래된 정보 안내 (D-006). 오류처럼 보이지 않게 빨간 글자 대신 옅은 상자로 둔다.
class _StaleBox extends StatelessWidget {
  const _StaleBox({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(color: c.cardSoft, borderRadius: BorderRadius.circular(16)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.schedule_rounded, size: 18, color: c.sub),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(keepAll(text), style: TextStyle(fontSize: 14, height: 1.5, color: c.body)),
          ),
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
    final c = context.gw;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(color: c.chip, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Icon(Icons.alarm_rounded, color: c.urgent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '저장한 뒤 ${deadlineChangeText(entry)}',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.body),
                ),
                Text(
                  '${before == null ? '미상' : shortDate(before)} → ${now == null ? '미상' : shortDate(now)}',
                  style: TextStyle(fontSize: 13, color: c.sub),
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
      // 세 상태 모두 연한 바탕 + 진한 글자로 같은 톤 (2026-11-01 팀장 요청, 목록 카드와 같음)
      'met' => const Pill('조건 충족'),
      'needs_check' => const Pill('확인 필요', tone: PillTone.check),
      'not_met' => const Pill('조건 미충족', tone: PillTone.urgent),
      _ => null,
    };
    int countOf(CheckState s) => rows.where((r) => r.state == s).fold(0, (n, r) => n + r.count);
    final checks = countOf(CheckState.check);
    final mets = countOf(CheckState.met);
    final intro = status == null
        ? '공고에서 찾은 조건입니다.'
        : checks > 0
        ? (mets > 0 ? '조건 $mets개 충족. $checks개는 직접 확인해 주세요.' : '$checks개 조건은 직접 확인해 주세요.')
        : '공고에서 찾은 조건을 내 프로필과 비교했습니다.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 36, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle('지원 전 체크리스트', trailing: badge),
          const SizedBox(height: 8),
          Text(keepAll(intro), style: TextStyle(fontSize: 14, height: 1.55, color: context.gw.sub)),
          const SizedBox(height: 8),
          for (final r in rows) _CheckLine(row: r),
          if (!notice.eligibility.extractionComplete)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(keepAll('첨부파일·이미지에 조건이 더 있을 수 있습니다. 지원 전에 원문을 확인해 주세요.'), style: captionStyle(context)),
            ),
        ],
      ),
    );
  }
}

/// 묶인 줄에서 접기 전에 보이는 근거 수. 이보다 많으면 '○개 더 보기'로 펼친다.
const checkPreviewCount = 3;

class _CheckLine extends StatefulWidget {
  const _CheckLine({required this.row});

  final CheckRow row;

  @override
  State<_CheckLine> createState() => _CheckLineState();
}

class _CheckLineState extends State<_CheckLine> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final check = row.state == CheckState.check;
    final c = context.gw;
    final box = switch (row.state) {
      CheckState.met => _box(c.point, Icon(Icons.check_rounded, size: 16, color: c.pointTick, semanticLabel: '충족')),
      CheckState.notMet => _box(
        c.urgentFill,
        Icon(Icons.close_rounded, size: 16, color: c.onUrgentFill, semanticLabel: '미충족'),
      ),
      CheckState.check => Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: c.checkBox,
          border: Border.all(color: c.checkLine, width: 2),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Icon(Icons.question_mark_rounded, size: 14, color: c.check, semanticLabel: '확인 필요'),
      ),
      CheckState.info => _box(c.neutral, Icon(Icons.remove_rounded, size: 16, color: c.sub, semanticLabel: '안내')),
    };
    final evidenceStyle = TextStyle(fontSize: 13.5, height: 1.5, color: c.sub);
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
                    // '학교' 같은 작은 이름표 + 본문
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (row.field case final field?)
                          Container(
                            height: 22,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(color: c.neutral, borderRadius: BorderRadius.circular(11)),
                            child: Center(
                              widthFactor: 1,
                              child: Text(
                                field,
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.sub),
                              ),
                            ),
                          ),
                        Text(
                          row.label,
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: check ? c.check : c.body),
                        ),
                      ],
                    ),
                    if (row.evidence case final single? when row.moreEvidence.isEmpty)
                      // 공고 원문 인용: 왼쪽 세로줄 상자. 짧은 근거는 형광펜, 길면 형광펜 없이 줄바꿈한다.
                      _Quote(
                        children: [
                          single.length <= 24
                              ? Text.rich(
                                  TextSpan(
                                    style: evidenceStyle,
                                    children: [markSpan(single, evidenceStyle, color: check ? c.checkMark : null)],
                                  ),
                                )
                              : Text(single, style: evidenceStyle),
                        ],
                      )
                    else if (row.evidences.isNotEmpty)
                      // 묶인 근거: 형광펜 없이 점 목록. checkPreviewCount개를 넘으면 접어 둔다 (D-015)
                      _Quote(
                        children: [
                          for (final e in _expanded ? row.evidences : row.evidences.take(checkPreviewCount))
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8, right: 8),
                                    child: Container(
                                      width: 4,
                                      height: 4,
                                      decoration: BoxDecoration(color: c.muted, shape: BoxShape.circle),
                                    ),
                                  ),
                                  Expanded(child: Text(e, style: evidenceStyle)),
                                ],
                              ),
                            ),
                          if (row.evidences.length > checkPreviewCount)
                            TextButton(
                              onPressed: () => setState(() => _expanded = !_expanded),
                              style: TextButton.styleFrom(
                                foregroundColor: c.sub,
                                minimumSize: const Size(48, 44),
                                padding: const EdgeInsets.only(right: 4),
                                textStyle: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(_expanded ? '접기' : '${row.evidences.length - checkPreviewCount}개 더 보기'),
                                  Icon(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
                                ],
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (row.note != null)
            Container(
              margin: const EdgeInsets.only(left: 36, top: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: c.summary,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomRight: Radius.circular(18),
                  bottomLeft: Radius.circular(5),
                ),
              ),
              child: Text(keepAll(row.note!), style: TextStyle(fontSize: 13.5, height: 1.55, color: c.body)),
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

/// '공고에 적힌 말' 인용 상자 (왼쪽 세로줄)
class _Quote extends StatelessWidget {
  const _Quote({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: c.line, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('공고에 적힌 말', style: TextStyle(fontSize: 12, color: c.muted)),
          const SizedBox(height: 2),
          ...children,
        ],
      ),
    );
  }
}

class _Reasons extends StatelessWidget {
  const _Reasons({required this.recommendation});

  final Recommendation recommendation;

  @override
  Widget build(BuildContext context) {
    final (words, soon) = reasonParts(recommendation);
    if (words.isEmpty && !soon) return const SizedBox.shrink();
    final style = TextStyle(fontSize: 16, height: 1.75, color: context.gw.body);
    final spans = <InlineSpan>[];
    for (var i = 0; i < words.length; i++) {
      if (i > 0) spans.add(const TextSpan(text: ', '));
      spans.add(markSpan(words[i], style));
    }
    if (words.isNotEmpty) {
      // 받침 있는 '전공'은 '과', 나머지는 '와'
      spans.add(TextSpan(text: words.last == '전공' ? '과 관련 있' : '와 관련 있'));
      spans.add(TextSpan(text: soon ? '고 ' : '습니다.'));
    }
    if (soon) spans.addAll([markSpan('2주 안에', style), const TextSpan(text: ' 마감됩니다.')]);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 36, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle('추천 이유'),
          const SizedBox(height: 12),
          Text.rich(TextSpan(style: style, children: spans)),
          const SizedBox(height: 8),
          Text(
            keepAll([
              '관심사·희망 직무·전공·마감 시기로 정한 순서입니다. 합격 가능성과는 관계없습니다.',
              if (recommendation.reasonCodes.contains('major_prior_match'))
                '학과 졸업생 진로는 커리어넷 학과정보 통계(2020 조사)로 계산했습니다.',
            ].join('\n')),
            style: TextStyle(fontSize: 12.5, height: 1.6, color: context.gw.muted),
          ),
        ],
      ),
    );
  }
}

/// 알림톡과 같은 행사의 학교 공지 (D-025). 누르면 그 공고 리포트로 간다.
class _Related extends StatelessWidget {
  const _Related({required this.notices, required this.onOpen});

  final List<({String noticeId, String title})> notices;
  final void Function(String noticeId) onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 36, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: SectionTitle('관련 학교 공지')),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('같은 행사를 학교 홈페이지에도 올렸습니다.', style: captionStyle(context)),
          ),
          const SizedBox(height: 12),
          for (final r in notices) ...[
            GwCard(
              padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
              onTap: () => onOpen(r.noticeId),
              child: Row(
                children: [
                  Expanded(
                    child: Text(keepAll(r.title), style: TextStyle(fontSize: 15, height: 1.45, color: c.body)),
                  ),
                  Icon(Icons.chevron_right_rounded, color: c.muted),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
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
    final c = context.gw;
    final events = <(DateTime, _Event)>[
      if (n.published != null) (n.published!.day, _event(shortDate(n.published!), sub: '게시', dot: _Dot.past)),
      if (notice.applicationStart != null)
        (notice.applicationStart!.day, _event(shortDate(notice.applicationStart!), sub: '신청 시작', dot: _Dot.past)),
      (day, _event('${shortDay(day)} · 오늘', dot: _Dot.today, color: c.accent)),
      if (deadline != null)
        (
          deadline.day,
          _event(
            '${shortDate(deadline)} · 신청 마감',
            dot: (left ?? 99) <= urgentDays ? _Dot.urgent : _Dot.main,
            bold: true,
            lines: [
              if (left != null) (left == 0 ? '오늘 마감' : 'D-$left'),
              if (!deadline.hasTime) '공고에 마감 시각 없음',
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
                keepAll(n.deadlineNote ?? '마감일이 공고에 나와 있지 않습니다. 학교 공지를 확인해 주세요.'),
                style: TextStyle(fontSize: 14, color: c.sub),
              ),
            ),
          const SizedBox(height: 20),
          // 오래된 정보 안내는 요약 아래 상자로 올렸다.
          if (stale == null && verified != null)
            Text(
              '${verified.month}월 ${verified.day}일 ${verified.hour.toString().padLeft(2, '0')}:${verified.minute.toString().padLeft(2, '0')} 기준',
              style: captionStyle(context),
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
    final c = context.gw;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 15,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
            color: color ?? (bold ? c.ink : c.body),
          ),
        ),
        if (sub != null) Text(sub!, style: TextStyle(fontSize: 13, color: c.muted)),
        for (final l in lines)
          Text(
            l,
            style: TextStyle(
              fontSize: 13,
              color: dot == _Dot.urgent && l.startsWith('D-') ? c.urgent : c.muted,
              fontWeight: dot == _Dot.urgent && l.startsWith('D-') ? FontWeight.w600 : FontWeight.w400,
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
    final c = context.gw;
    final dot = switch (child.dot) {
      _Dot.past => Container(
        width: 10,
        height: 10,
        margin: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(color: c.faint, shape: BoxShape.circle),
      ),
      _Dot.today => Container(
        width: 12,
        height: 12,
        margin: const EdgeInsets.only(top: 5),
        decoration: BoxDecoration(
          color: c.card,
          shape: BoxShape.circle,
          border: Border.all(color: c.point, width: 3),
        ),
      ),
      _Dot.main => Container(
        width: 12,
        height: 12,
        margin: const EdgeInsets.only(top: 5),
        decoration: BoxDecoration(color: c.point, shape: BoxShape.circle),
      ),
      _Dot.urgent => Container(
        width: 12,
        height: 12,
        margin: const EdgeInsets.only(top: 5),
        decoration: BoxDecoration(color: c.urgentFill, shape: BoxShape.circle),
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
                    child: Container(width: 2, margin: const EdgeInsets.only(top: 4), color: c.line),
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
