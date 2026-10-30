import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../data/models.dart';
import 'format.dart';

/// 오늘의 귀띔 내용 (D-009, D-018). list_recommendations·list_saved_notices 응답만으로 고른다. 점수는 쓰지 않는다.
/// 소식마다 조건이 있고, 맞는 공고가 있을 때만 그 소식을 보인다. 문장은 템플릿이다 (SPEC: LLM 실시간 브리핑 제외).
class Briefing {
  const Briefing({
    this.savedSoon = const [],
    this.urgent,
    this.fresh = const [],
    this.career = const [],
    this.changed = const [],
    this.majorPick,
  });

  /// 저장한 모집 중 공고 중 확정 마감이 이틀 안에 오는 것 (가까운 순)
  final List<SavedEntry> savedSoon;

  /// 7일 안에 마감되는 가장 가까운 공고 (확정 마감만, 맞춤 추천이면 관련 공고 중에서). 저장해서 위에 이미 나온 공고는 뺀다.
  final RecommendationEntry? urgent;

  /// 최근 3일 안에 게시된 맞춤 공고 (서버 추천 순서)
  final List<RecommendationEntry> fresh;

  /// 관심 분야와는 관련 없지만 희망 직무와 관련된 공고. 관심 분야를 입력한 사용자에게만.
  final List<RecommendationEntry> career;

  /// 저장한 뒤 마감이 바뀐 모집 중 공고
  final List<SavedEntry> changed;

  /// 학과 통계로만 고른 7일 안 마감 공고 하나 (D-021). 고른 분야와 관련된 마감 임박과 따로, 안내 표시와 함께 보인다.
  final RecommendationEntry? majorPick;

  int get count => [
    savedSoon.isNotEmpty,
    urgent != null,
    fresh.isNotEmpty,
    career.isNotEmpty,
    changed.isNotEmpty,
    majorPick != null,
  ].where((b) => b).length;

  /// 전할 소식이 없으면 브리핑을 띄우지 않는다.
  bool get isEmpty => count == 0;
}

const urgentDays = 7;

/// 저장 공고 마감 알림을 보내는 남은 날 (0이면 오늘 마감)
const savedSoonDays = 2;

/// '새 공고'로 보는 게시일 범위: 오늘을 포함해 최근 3일
const freshDays = 3;

/// 학생이 고른 관심 분야·희망 직무·전공과 관련된 이유. 학과 통계(major_prior_match)는 학생이 고른 것이 아니라 뺀다 (D-021).
const chosenReasons = {'interest_match', 'role_match', 'major_match'};

/// 관심 분야·희망 직무·전공 중 하나라도 관련된 공고
bool isRelated(RecommendationEntry e) => e.recommendation.reasonCodes.any(chosenReasons.contains);

/// 고른 것과는 관련 없고 학과 통계로만 추천된 공고 (D-021)
bool isMajorPick(RecommendationEntry e) =>
    !isRelated(e) && e.recommendation.reasonCodes.contains('major_prior_match');

/// 학과 통계 추천 중 화면에 보일 것: 학생이 그만 보기로 하지 않았고, '관심 없어요'라고 한 공고가 아닌 것
List<RecommendationEntry> majorPicks(RecommendationList list, MajorPickState picks, String? majorId, DateTime today) =>
    list.personalized && picks.allows(majorId, today)
    ? [
        for (final e in list.items)
          if (isMajorPick(e) && picks.decided[e.notice.noticeId] != false) e,
      ]
    : const [];

/// 마감 임박·다가오는 마감에 넣을 공고. 맞춤 추천이면 관련 공고만 넣는다.
/// 마감이 가깝다는 것만으로 관련 없는 공고를 앞에 세우지 않는다 (SPEC §5 추천).
List<RecommendationEntry> deadlineCandidates(RecommendationList list) => list.personalized
    ? [
        for (final e in list.items)
          if (isRelated(e)) e,
      ]
    : list.items;

/// [hasInterests]: 프로필에 관심 분야가 있는지. 없으면 '관심 분야 밖' 소식을 만들지 않는다.
/// [picks]·[majorId]: 학과 통계 추천을 보일지 정하는 기기 기록과 프로필 학과 (D-021).
Briefing buildBriefing(
  RecommendationList list,
  List<SavedEntry> saved,
  DateTime today, {
  bool hasInterests = false,
  MajorPickState picks = const MajorPickState(),
  String? majorId,
}) {
  final day = DateTime(today.year, today.month, today.day);
  final savedSoon = [
    for (final s in saved)
      if ((daysLeft(s.notice, today) ?? 99) <= savedSoonDays) s,
  ]..sort((a, b) => a.notice.applicationDeadline!.date.compareTo(b.notice.applicationDeadline!.date));
  final soonIds = {for (final s in savedSoon) s.notice.noticeId};

  RecommendationEntry? urgent;
  int? nearest;
  for (final e in deadlineCandidates(list)) {
    if (soonIds.contains(e.notice.noticeId)) continue;
    final left = daysLeft(e.notice, today);
    if (left != null && left <= urgentDays && (nearest == null || left < nearest)) {
      urgent = e;
      nearest = left;
    }
  }

  bool isFresh(RecommendationEntry e) {
    final published = e.notice.published?.day;
    if (published == null || published.isAfter(day)) return false;
    return day.difference(published).inDays < freshDays;
  }

  final fresh = list.personalized
      ? [
          for (final e in list.items)
            if (isRelated(e) && isFresh(e)) e,
        ]
      : const <RecommendationEntry>[];
  final freshIds = {for (final e in fresh) e.notice.noticeId};
  final career = list.personalized && hasInterests
      ? [
          for (final e in list.items)
            if (e.recommendation.reasonCodes.contains('role_match') &&
                !e.recommendation.reasonCodes.contains('interest_match') &&
                !freshIds.contains(e.notice.noticeId))
              e,
        ]
      : const <RecommendationEntry>[];

  // 아직 답하지 않은 학과 통계 추천 중 7일 안 마감이 가장 가까운 것
  RecommendationEntry? majorPick;
  int? pickNearest;
  for (final e in majorPicks(list, picks, majorId, today)) {
    if (soonIds.contains(e.notice.noticeId) || picks.decided.containsKey(e.notice.noticeId)) continue;
    final left = daysLeft(e.notice, today);
    if (left != null && left <= urgentDays && (pickNearest == null || left < pickNearest)) {
      majorPick = e;
      pickNearest = left;
    }
  }

  return Briefing(
    savedSoon: savedSoon,
    urgent: urgent,
    fresh: fresh,
    career: career,
    majorPick: majorPick,
    changed: [
      for (final s in saved)
        if (s.deadlineChanged && s.notice.lifecycleStatus == 'open') s,
    ],
  );
}

/// 지원 자격 확인이 필요한 이유. 서버 판정(condition_results)에서 판정하지 못한 조건만 이름을 붙인다.
/// 조건 목록 밖의 문장(평점 등)만 남았으면 원문 확인 한 줄.
List<String> checkReasons(Recommendation r) {
  final out = [
    for (final c in r.conditionResults)
      if (c.status == 'unknown')
        c.unknownReason == 'profile_missing'
            ? '${conditionFieldLabel(c.field)}: 프로필에 없어 비교하지 못했어요'
            : '${conditionFieldLabel(c.field)}: 원문에서 확인 필요',
  ];
  return out.isEmpty ? const ['자동으로 비교하지 못한 조건이 있어요. 원문에서 확인해 주세요.'] : out;
}

/// 저장 이후 마감 변경 문장. 기준은 최신 마감이다 (SPEC §5).
String deadlineChangeText(SavedEntry e) {
  final before = e.saved.savedDeadlineSnapshot;
  final now = e.notice.applicationDeadline;
  if (before == null) return '마감일이 새로 나왔어요';
  if (now == null) return '마감일이 공고에서 빠졌어요';
  final days = now.day.difference(before.day).inDays;
  if (days > 0) return '마감이 $days일 늦춰졌어요';
  if (days < 0) return '마감이 ${-days}일 당겨졌어요';
  return '마감 시각이 바뀌었어요';
}

/// 학과 통계 추천에 대한 학생의 답 (D-021). 기기에만 저장하고 서버에 보내지 않는다.
/// 학습이 아니라 정해진 규칙이다: '관심 없어요'가 [majorPickStopAfter]번 이어지면 [majorPickPauseDays]일 동안 보이지 않는다.
/// 학과를 바꾸면 처음부터 다시 본다.
class MajorPickState {
  const MajorPickState({this.majorId, this.decided = const {}, this.declineStreak = 0, this.stoppedOn});

  /// 답할 때의 프로필 학과
  final String? majorId;

  /// 공고 ID → 관심 있음(true) / 관심 없음(false)
  final Map<String, bool> decided;

  /// 이어진 '관심 없어요' 수
  final int declineStreak;

  /// 그만 보이기 시작한 날
  final DateTime? stoppedOn;

  bool allows(String? profileMajor, DateTime today) {
    final stopped = stoppedOn;
    if (stopped == null || profileMajor != majorId) return true;
    return DateTime(today.year, today.month, today.day).difference(stopped).inDays >= majorPickPauseDays;
  }

  /// 답을 더한 다음 상태. 학과가 바뀌었으면 이전 답은 버린다.
  MajorPickState answer(String noticeId, bool interested, String? profileMajor, DateTime today) {
    final base = profileMajor == majorId ? this : MajorPickState(majorId: profileMajor);
    final streak = interested ? 0 : base.declineStreak + 1;
    final stop = streak >= majorPickStopAfter;
    return MajorPickState(
      majorId: profileMajor,
      decided: {...base.decided, noticeId: interested},
      declineStreak: stop ? 0 : streak,
      stoppedOn: stop ? DateTime(today.year, today.month, today.day) : base.stoppedOn,
    );
  }

  Map<String, Object?> toJson() => {
    'major_id': majorId,
    'decided': decided,
    'decline_streak': declineStreak,
    'stopped_on': stoppedOn?.toIso8601String().substring(0, 10),
  };

  factory MajorPickState.fromJson(Map<String, dynamic> m) => MajorPickState(
    majorId: m['major_id'] as String?,
    decided: {for (final e in (m['decided'] as Map).entries) e.key as String: e.value as bool},
    declineStreak: m['decline_streak'] as int? ?? 0,
    stoppedOn: m['stopped_on'] == null ? null : DateTime.parse(m['stopped_on'] as String),
  );
}

/// '관심 없어요'가 이만큼 이어지면 학과 통계 추천을 쉰다.
const majorPickStopAfter = 3;

/// 쉬는 기간(일). 지나면 다시 보인다.
const majorPickPauseDays = 30;

/// 하루 첫 실행 기록과 학과 통계 추천 답. 기기에만 저장하고 서버에 보내지 않는다 (D-009, D-021).
abstract class BriefingStore {
  Future<bool> shownOn(DateTime day);
  Future<void> markShown(DateTime day);
  Future<MajorPickState> majorPicks();
  Future<void> saveMajorPicks(MajorPickState state);
}

String _key(DateTime d) => '${d.year}-${d.month}-${d.day}';

class PrefsBriefingStore implements BriefingStore {
  static const _name = 'briefing_shown_on';

  @override
  Future<bool> shownOn(DateTime day) async => (await SharedPreferences.getInstance()).getString(_name) == _key(day);

  @override
  Future<void> markShown(DateTime day) async => (await SharedPreferences.getInstance()).setString(_name, _key(day));

  static const _picks = 'major_picks';

  @override
  Future<MajorPickState> majorPicks() async {
    final raw = (await SharedPreferences.getInstance()).getString(_picks);
    return raw == null ? const MajorPickState() : MajorPickState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  @override
  Future<void> saveMajorPicks(MajorPickState state) async =>
      (await SharedPreferences.getInstance()).setString(_picks, jsonEncode(state.toJson()));
}

class MemoryBriefingStore implements BriefingStore {
  MemoryBriefingStore({this.alwaysShown = false});

  /// 테스트에서 브리핑이 자동으로 뜨지 않게 한다.
  final bool alwaysShown;
  String? _shown;

  @override
  Future<bool> shownOn(DateTime day) async => alwaysShown || _shown == _key(day);

  @override
  Future<void> markShown(DateTime day) async => _shown = _key(day);

  MajorPickState picks = const MajorPickState();

  @override
  Future<MajorPickState> majorPicks() async => picks;

  @override
  Future<void> saveMajorPicks(MajorPickState state) async => picks = state;
}
