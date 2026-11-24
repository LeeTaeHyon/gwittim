import '../data/application_case.dart';
import '../data/models.dart';
import 'briefing_data.dart';
import 'case_view.dart';
import 'format.dart';

// 홈 한 목록 (D-050): 이번 주 마감 → 새 공고 → 마감이 먼 맞춤 공고. 같은 공고는 홈 줄에 한 번만 나온다.
// 화면과 떼어 둔 계산이다. 점수는 쓰지 않고 서버가 준 추천 순서만 쓴다.

/// 이번 주 마감 줄 수 (맞춤 추천)
const homeWeekRows = 5;

/// 최신 모드(프로필에 관심 분야·직무·전공이 없음)의 마감 줄 수
const homeLatestRows = 3;

/// 새 공고 줄 수
const homeFreshRows = 3;

/// 마감이 먼 맞춤 공고 줄 수
const homeLaterRows = 3;

/// 7일 안 마감이 없을 때 '다음 마감'을 찾는 범위(일)
const homeNextDays = 14;

/// 홈 한 줄
class HomeRow {
  const HomeRow({
    required this.notice,
    this.recommendation,
    this.saved,
    this.majorPick = false,
    this.fresh = false,
    this.view,
    this.changeSeen = false,
  });

  final NoticeSummary notice;

  /// 추천 정보. 저장만 한 공고(추천 목록에 없음)면 null
  final Recommendation? recommendation;

  /// 저장 정보. 저장한 공고면 있다.
  final SavedEntry? saved;

  /// 졸업생 진로 추천 (D-021)
  final bool majorPick;

  /// 최근 3일 안에 게시된 관련 공고 (맞춤 추천일 때만)
  final bool fresh;

  /// 지원 건 문구(상태 이름·다음 할 일·남은 날, D-052). 지원 건 기록을 쓰는 홈에서 저장한 공고만.
  final CaseView? view;

  /// 리포트를 열어 이미 본 마감 변경
  final bool changeSeen;

  String get id => notice.noticeId;

  /// 저장한 뒤 마감이 바뀐 공고(리포트에서 이미 본 변경은 빼다)
  bool get deadlineChanged => (saved?.deadlineChanged ?? false) && !changeSeen;
}

/// 홈 귀띔 말풍선의 건수 (§4.4). 셋 다 0이면 말풍선을 만들지 않는다.
class HomeNudge {
  const HomeNudge({this.dueToday = 0, this.startToday = 0, this.changed = 0, this.fresh = 0, this.caseIds = const {}});

  /// 오늘 마감: 저장한 공고와 마감 후보(관련 공고) 중 오늘 마감. 졸업생 진로 추천은 세지 않는다.
  /// 끝난 지원 건과, 오늘 앞선 실행에서 이미 강조한 지원 건은 세지 않는다(D-052).
  final int dueToday;

  /// 신청 시작: 저장한 공고(지원 건) 중 저장·준비 중이고 신청 시작일이 오늘인 것 (팀장 결정 2026-11-23)
  final int startToday;

  /// 건수에 들어간 지원 건. 홈이 그린 뒤 오늘 강조한 것으로 기록한다(하루 1번).
  final Set<String> caseIds;

  /// 저장한 뒤 마감이 바뀐 모집 중 공고 (브리핑 '마감 변경'과 같은 규칙)
  final int changed;

  /// 최근 3일 안에 게시된 관련 공고 전체 (브리핑 '새 공고'와 같은 규칙)
  final int fresh;
}

class HomeSections {
  const HomeSections({
    required this.personalized,
    this.deadlines = const [],
    this.weekTotal = 0,
    this.fresh = const [],
    this.later = const [],
    this.changed = const [],
    this.nudge,
  });

  /// 맞춤 추천인지. 아니면 최신 모드다.
  final bool personalized;

  /// 마감 구역에 보이는 줄. 7일 안 후보 앞의 몇 건이고, 7일 안이 없으면 '다음 마감' 1건, 그것도 없으면 비어 있다.
  final List<HomeRow> deadlines;

  /// 7일 안 후보 전체 수 (화면에 안 나온 것 포함)
  final int weekTotal;

  /// 새 공고 구역 줄
  final List<HomeRow> fresh;

  /// 마감이 먼 맞춤 공고 구역 줄
  final List<HomeRow> later;

  /// 홈 맨 아래 마감 변경 카드: 마감이 바뀐 저장 공고 중 홈 줄 어디에도 나오지 않은 것 (§5.5)
  final List<SavedEntry> changed;

  /// 귀띔 말풍선. 달라진 것이 없으면 null
  final HomeNudge? nudge;

  /// 마감 구역이 7일 안이 아니라 '다음 마감' 1건인지
  bool get isNext => weekTotal == 0 && deadlines.isNotEmpty;

  /// 홈 줄에 나온 공고 ID (순서대로)
  List<String> get rowIds => [
    for (final r in [...deadlines, ...fresh, ...later]) r.id,
  ];
}

/// [picks]·[majorId]: 졸업생 진로 추천을 보일지 정하는 기기 기록과 프로필 학과 (D-021).
/// [cases]: 지원 건 기록(D-052). 있으면 끝난 지원 건은 홈 줄에서 빼고, 저장한 공고 줄에 지원 건 문구를 붙인다.
/// [emphasizedEarlier]: 오늘 앞선 실행에서 이미 강조한 지원 건(말풍선 건수에서 빼다).
HomeSections buildHomeSections(
  RecommendationList list,
  List<SavedEntry> saved,
  DateTime today, {
  MajorPickState picks = const MajorPickState(),
  String? majorId,
  Map<String, ApplicationCase>? cases,
  bool Function(String id)? emphasizedEarlier,
}) {
  final ended = <String>{};
  final views = <String, CaseView>{};
  if (cases != null) {
    for (final s in saved) {
      final id = s.notice.noticeId;
      if (isEnded(stateOfSaved(s, cases[id], today))) ended.add(id);
      views[id] = caseView(s.notice, cases[id], now: today);
    }
  }
  bool early(String id) => cases?[id] != null && (emphasizedEarlier?.call(id) ?? false);
  final personalized = list.personalized;
  final rank = <String, int>{};
  for (final (i, e) in list.items.indexed) {
    rank.putIfAbsent(e.notice.noticeId, () => i);
  }
  final recs = {for (final e in list.items.reversed) e.notice.noticeId: e}; // 같은 ID면 앞의 것
  final savedById = {for (final s in saved) s.notice.noticeId: s};
  final candidates = deadlineCandidates(list);
  final pickEntries = majorPicks(list, picks, majorId, today);
  final pickIds = {for (final e in pickEntries) e.notice.noticeId};
  final freshIds = {for (final e in freshRelated(list, today)) e.notice.noticeId};

  HomeRow row(NoticeSummary notice) {
    final id = notice.noticeId;
    final s = savedById[id];
    return HomeRow(
      notice: notice,
      recommendation: recs[id]?.recommendation,
      saved: s,
      majorPick: pickIds.contains(id),
      fresh: freshIds.contains(id),
      view: views[id],
      changeSeen: s != null && cases != null && changeSeenFor(s, cases[id]),
    );
  }

  // 마감 후보: A 저장한 공고, B 관련 공고(최신 모드는 목록 전체), C 졸업생 진로 추천 중 [from]~[to]일 안 마감.
  // 마감 가까운 순 → 같은 날이면 저장한 공고 먼저 → 추천 순서(추천 목록에 없는 저장 공고는 뒤).
  List<HomeRow> within(int from, int to) {
    final found = <String, NoticeSummary>{};
    for (final n in [
      for (final s in saved) s.notice,
      for (final e in candidates) e.notice,
      for (final e in pickEntries) e.notice,
    ]) {
      if (ended.contains(n.noticeId)) continue; // 끝난 지원 건은 추천 목록에 있어도 뺀다 (D-052)
      final left = daysLeft(n, today);
      if (left != null && left >= from && left <= to) found.putIfAbsent(n.noticeId, () => n);
    }
    final order = {for (final (i, id) in found.keys.indexed) id: i};
    final noRank = list.items.length;
    return [for (final n in found.values) row(n)]..sort((a, b) {
      final byDay = daysLeft(a.notice, today)!.compareTo(daysLeft(b.notice, today)!);
      if (byDay != 0) return byDay;
      final bySaved = (a.saved == null ? 1 : 0).compareTo(b.saved == null ? 1 : 0);
      if (bySaved != 0) return bySaved;
      final byRank = (rank[a.id] ?? noRank).compareTo(rank[b.id] ?? noRank);
      return byRank != 0 ? byRank : order[a.id]!.compareTo(order[b.id]!);
    });
  }

  final week = within(0, urgentDays);
  final deadlines = week.isEmpty
      ? within(urgentDays + 1, homeNextDays).take(1).toList()
      : week.take(personalized ? homeWeekRows : homeLatestRows).toList();
  final shown = {for (final r in deadlines) r.id};

  List<HomeRow> pick(bool Function(RecommendationEntry e) test, int count) {
    final out = <HomeRow>[];
    for (final e in list.items) {
      if (out.length >= count) break;
      if (shown.contains(e.notice.noticeId) || ended.contains(e.notice.noticeId) || !test(e)) continue;
      shown.add(e.notice.noticeId);
      out.add(row(e.notice));
    }
    return out;
  }

  final weekIds = {for (final r in week) r.id};
  final fresh = personalized ? pick((e) => freshIds.contains(e.notice.noticeId), homeFreshRows) : const <HomeRow>[];
  final later = personalized
      ? pick((e) => isRelated(e) && !weekIds.contains(e.notice.noticeId), homeLaterRows)
      : const <HomeRow>[];

  final changed = [
    for (final s in changedSaved(saved))
      if (cases == null || !changeSeenFor(s, cases[s.notice.noticeId])) s,
  ];
  final dueIds = {
    for (final s in saved)
      if (daysLeft(s.notice, today) == 0) s.notice.noticeId,
    // 최신 모드에서는 목록 전체가 후보라 저장한 공고만 센다.
    if (personalized)
      for (final e in candidates)
        if (daysLeft(e.notice, today) == 0) e.notice.noticeId,
  }..removeWhere((id) => ended.contains(id) || early(id));
  final startIds = {
    if (cases != null)
      for (final s in saved)
        if (startsToday(s, cases[s.notice.noticeId], today) && !early(s.notice.noticeId)) s.notice.noticeId,
  };
  final caseIds = {
    for (final id in {...dueIds, ...startIds})
      if (cases?[id] != null) id,
  };
  final nudge = dueIds.length + startIds.length + changed.length + freshIds.length == 0
      ? null
      : HomeNudge(
          dueToday: dueIds.length,
          startToday: startIds.length,
          changed: changed.length,
          fresh: freshIds.length,
          caseIds: caseIds,
        );

  // 홈 줄(마감·새 공고·마감이 먼 맞춤 공고)에 나온 공고는 줄 메타에 변경 문구를 두고 카드는 그리지 않는다.
  return HomeSections(
    personalized: personalized,
    deadlines: deadlines,
    weekTotal: week.length,
    fresh: fresh,
    later: later,
    changed: [
      for (final s in changed)
        if (!shown.contains(s.notice.noticeId)) s,
    ],
    nudge: nudge,
  );
}

/// 줄 메타의 추천 이유 (§5.6): 관련 이유가 하나면 '관심 분야'·'희망 직무'·'전공', 둘 이상이면 '관심·직무'처럼 줄여 잇는다.
/// 관련 이유가 없으면(졸업생 진로 추천만, 저장만 한 공고, 최신 모드) 빈 문자열.
String homeReason(Recommendation? r, {required bool personalized}) {
  if (r == null || !personalized) return '';
  final codes = [
    for (final code in _reasonOrder)
      if (r.reasonCodes.contains(code)) code,
  ];
  if (codes.length == 1) return personalReasons[codes.single]!;
  return codes.map((c) => _reasonShort[c]!).join('·');
}

const _reasonOrder = ['interest_match', 'role_match', 'major_match'];
const _reasonShort = {'interest_match': '관심', 'role_match': '직무', 'major_match': '전공'};
