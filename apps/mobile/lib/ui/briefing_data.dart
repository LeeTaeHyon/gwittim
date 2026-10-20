import 'package:shared_preferences/shared_preferences.dart';

import '../data/models.dart';
import 'format.dart';

/// 오늘의 귀띔 내용 (D-009). list_recommendations·list_saved_notices 응답만으로 센다. 점수는 쓰지 않는다.
class Briefing {
  const Briefing({this.urgent, this.related = const [], this.changed = const []});

  /// 7일 안에 마감되는 가장 가까운 공고 (확정 마감만)
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

Briefing buildBriefing(RecommendationList list, List<SavedEntry> saved, DateTime today) {
  RecommendationEntry? urgent;
  int? nearest;
  for (final e in list.items) {
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
              if (e.recommendation.reasonCodes.any(personalReasons.containsKey)) e,
          ]
        : const [],
    changed: [
      for (final s in saved)
        if (s.deadlineChanged && s.notice.lifecycleStatus == 'open') s,
    ],
  );
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
