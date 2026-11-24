import '../data/application_case.dart';
import '../data/models.dart';

/// 지원 건의 상태 이름·다음 할 일·남은 날 (care-loop-impl-spec §3, D-052).
///
/// 홈·달력·저장함·리포트·상세 분석은 이 결과 문자열만 쓴다. 화면에서 남은 날·상태 문구를 따로 만들지 않는다.
class CaseView {
  const CaseView({required this.stateLabel, required this.next, required this.items, required this.remaining, required this.ended});

  /// '저장' '준비 중' '신청함' '이번엔 안 함' '마감 지남' '모집 끝남' '학교 공지에서 삭제됨'. 지원 건이 아니면 null.
  final String? stateLabel;

  /// 다음 할 일 하나. 끝난 상태면 null.
  final CaseItem? next;

  /// 리포트 카드에 보일 전체 순서. 끝난 상태면 빈 목록.
  final List<CaseItem> items;

  /// 남은 날 문구.
  final String remaining;

  /// applied·skipped·missed·closed·removed.
  final bool ended;
}

class CaseItem {
  const CaseItem({required this.text, required this.kind, this.evidence, this.url});

  final String text;

  /// '확인' 또는 '행동'.
  final String kind;

  /// 근거 문구(원문 문구 또는 공고 날짜의 evidence). 앱 안내 항목은 null.
  final String? evidence;
  final String? url;

  @override
  bool operator ==(Object other) =>
      other is CaseItem && other.text == text && other.kind == kind && other.evidence == evidence && other.url == url;

  @override
  int get hashCode => Object.hash(text, kind, evidence, url);

  @override
  String toString() => 'CaseItem($text)';
}

const _stateLabels = {
  CaseState.saved: '저장',
  CaseState.preparing: '준비 중',
  CaseState.applied: '신청함',
  CaseState.skipped: '이번엔 안 함',
  CaseState.missed: '마감 지남',
  CaseState.closed: '모집 끝남',
  CaseState.removed: '학교 공지에서 삭제됨',
};

/// [applicationStart]·[applyUrl]은 공고 상세(`Notice`)에만 있다. 목록 응답(`NoticeSummary`)에는 없어
/// 넘기지 않으면 신청 시작 항목이 없고 신청 경로는 원문(`sourceUrl`)으로 간다(보고: 정하지 못한 것).
CaseView caseView(
  NoticeSummary n,
  ApplicationCase? c, {
  required DateTime now,
  DateInfo? applicationStart,
  String? applyUrl,
}) {
  final state = c == null ? null : effectiveState(c, n, now);
  final ended = state != null && isEnded(state);
  final remaining = remainingText(n, now);
  if (ended) {
    return CaseView(stateLabel: _stateLabels[state], next: null, items: const [], remaining: remaining, ended: true);
  }

  final needsCheck = c?.eligibilityStatus == 'needs_check';
  const check = CaseItem(text: '지원 조건 직접 확인', kind: '확인', evidence: '서버 판정');
  final items = <CaseItem>[
    if (applicationStart != null && _startsLater(applicationStart, now))
      CaseItem(text: '${_monthDay(applicationStart)} 신청 시작', kind: '확인', evidence: applicationStart.evidence),
    if (needsCheck && state == CaseState.saved) check,
    _route(n, applyUrl),
    if (needsCheck && state == CaseState.preparing) check,
  ];
  final next = items.first;
  final deadline = n.applicationDeadline;
  if (deadline != null) {
    items.add(CaseItem(text: '${_monthDay(deadline)} 마감', kind: '확인', evidence: deadline.evidence));
  }
  return CaseView(
    stateLabel: state == null ? null : _stateLabels[state],
    next: next,
    items: List.unmodifiable(items),
    remaining: remaining,
    ended: false,
  );
}

CaseItem _route(NoticeSummary n, String? applyUrl) {
  if (applyUrl != null) return CaseItem(text: '신청 사이트에서 신청', kind: '행동', url: applyUrl);
  if (n.sourceUrl != null) return CaseItem(text: '원문에서 신청 방법 확인', kind: '행동', url: n.sourceUrl);
  return const CaseItem(text: '받은 알림톡에서 신청 방법 확인', kind: '행동');
}

/// 신청 시작이 지금보다 뒤인가. 시각·시간대가 있으면 그 시각, 아니면 날짜로(그 날 0시부터 시작으로 본다).
bool _startsLater(DateInfo start, DateTime now) {
  final at = deadlineInstant(start);
  if (at != null) return now.toUtc().isBefore(at);
  return _today(now).isBefore(DateTime(start.day.year, start.day.month, start.day.day));
}

DateTime _today(DateTime now) => DateTime(now.year, now.month, now.day);

/// 'M월 D일' + 시각이 있으면 ' HH:MM'.
String _monthDay(DateInfo d) => '${d.day.month}월 ${d.day.day}일${d.hasTime ? ' ${d.time}' : ''}';

/// 남은 날 문구 (care-loop-impl-spec §3.3).
String remainingText(NoticeSummary n, DateTime now) {
  if (n.lifecycleStatus == 'removed') return '학교 공지에서 삭제됨';
  if (n.lifecycleStatus == 'closed') return '모집 끝남';
  final d = n.applicationDeadline;
  if (d == null) return '마감일 미상';
  if (deadlinePassed(d, now)) return '마감 지남';
  final days = DateTime(d.day.year, d.day.month, d.day.day).difference(_today(now)).inDays;
  if (days == 0) return d.hasTime ? '오늘 ${d.time} 마감' : '오늘 마감 · 시각 미상';
  if (days == 1 && deadlineInstant(d) != null && d.time!.compareTo('12:00') < 0) return '내일 ${d.time} 마감';
  return 'D-$days · ${_monthDay(d)} 마감';
}
