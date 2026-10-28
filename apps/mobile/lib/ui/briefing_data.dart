import 'package:shared_preferences/shared_preferences.dart';

import '../data/models.dart';
import 'format.dart';

/// 오늘의 귀띔 내용 (D-009). list_recommendations·list_saved_notices 응답만으로 센다. 점수는 쓰지 않는다.
class Briefing {
  const Briefing({this.urgent, this.related = const [], this.changed = const []});

  /// 7일 안에 마감되는 가장 가까운 공고 (확정 마감만, 맞춤 추천이면 관련 공고 중에서)
  final RecommendationEntry? urgent;

  /// 관심 분야·희망 직무·전공과 관련된 공고 (서버 추천 순서)
  final List<RecommendationEntry> related;

  /// 저장한 뒤 마감이 바뀐 모집 중 공고
  final List<SavedEntry> changed;

  int get count => [urgent != null, related.isNotEmpty, changed.isNotEmpty].where((b) => b).length;

  /// 전할 소식이 없으면 브리핑을 띄우지 않는다.
  bool get isEmpty => count == 0;
}

const urgentDays = 7;

/// 관심 분야·희망 직무·전공 중 하나라도 관련된 공고
bool isRelated(RecommendationEntry e) => e.recommendation.reasonCodes.any(personalReasons.containsKey);

/// 마감 임박·다가오는 마감에 넣을 공고. 맞춤 추천이면 관련 공고만 넣는다.
/// 마감이 가깝다는 것만으로 관련 없는 공고를 앞에 세우지 않는다 (SPEC §5 추천).
List<RecommendationEntry> deadlineCandidates(RecommendationList list) => list.personalized
    ? [
        for (final e in list.items)
          if (isRelated(e)) e,
      ]
    : list.items;

Briefing buildBriefing(RecommendationList list, List<SavedEntry> saved, DateTime today) {
  RecommendationEntry? urgent;
  int? nearest;
  for (final e in deadlineCandidates(list)) {
    final left = daysLeft(e.notice, today);
    if (left != null && left <= urgentDays && (nearest == null || left < nearest)) {
      urgent = e;
      nearest = left;
    }
  }
  return Briefing(
    urgent: urgent,
    related: list.personalized
        ? [
            for (final e in list.items)
              if (isRelated(e)) e,
          ]
        : const [],
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

/// 하루 첫 실행 기록. 기기에만 저장하고 서버에 보내지 않는다 (D-009).
abstract class BriefingStore {
  Future<bool> shownOn(DateTime day);
  Future<void> markShown(DateTime day);
}

String _key(DateTime d) => '${d.year}-${d.month}-${d.day}';

class PrefsBriefingStore implements BriefingStore {
  static const _name = 'briefing_shown_on';

  @override
  Future<bool> shownOn(DateTime day) async => (await SharedPreferences.getInstance()).getString(_name) == _key(day);

  @override
  Future<void> markShown(DateTime day) async => (await SharedPreferences.getInstance()).setString(_name, _key(day));
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
}
