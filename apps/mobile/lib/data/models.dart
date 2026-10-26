// contracts/ 스키마와 같은 필드 이름(snake_case JSON)을 읽는 모델.
// 앱은 추천 점수를 계산하지 않는다 (SPEC §7). 서버·샘플이 준 값을 표시만 한다.

class DateInfo {
  const DateInfo({
    required this.date,
    required this.time,
    required this.timezone,
    required this.precision,
    required this.evidence,
  });

  /// YYYY-MM-DD
  final String date;

  /// HH:MM, 미상이면 null
  final String? time;

  /// IANA 이름, 미상이면 null
  final String? timezone;

  /// 'date' 또는 'minute'
  final String precision;
  final String evidence;

  bool get hasTime => precision == 'minute' && time != null;

  DateTime get day => DateTime.parse(date);

  static DateInfo? fromJson(Object? json) {
    if (json == null) return null;
    final m = json as Map<String, dynamic>;
    return DateInfo(
      date: m['date'] as String,
      time: m['time'] as String?,
      timezone: m['timezone'] as String?,
      precision: m['precision'] as String,
      evidence: m['evidence'] as String,
    );
  }
}

class NoticeSummary {
  const NoticeSummary({
    required this.noticeId,
    required this.noticeVersion,
    required this.title,
    required this.category,
    required this.sourceUrl,
    required this.published,
    required this.applicationDeadline,
    required this.deadlineNote,
    required this.lifecycleStatus,
  });

  final String noticeId;
  final int noticeVersion;
  final String title;
  final String category;
  final String sourceUrl;
  final DateInfo? published;
  final DateInfo? applicationDeadline;
  final String? deadlineNote;

  /// open / closed / unknown / removed
  final String lifecycleStatus;

  factory NoticeSummary.fromJson(Map<String, dynamic> m) => NoticeSummary(
    noticeId: m['notice_id'] as String,
    noticeVersion: m['notice_version'] as int,
    title: m['title'] as String,
    category: m['category'] as String,
    sourceUrl: m['source_url'] as String,
    published: DateInfo.fromJson(m['published']),
    applicationDeadline: DateInfo.fromJson(m['application_deadline']),
    deadlineNote: m['deadline_note'] as String?,
    lifecycleStatus: m['lifecycle_status'] as String,
  );
}

class EligibilityCondition {
  const EligibilityCondition({required this.field, required this.evidence});

  final String field;
  final String evidence;
}

class Eligibility {
  const Eligibility({
    required this.conditions,
    required this.unresolvedEvidence,
    required this.extractionComplete,
    required this.explicitlyUnrestricted,
    required this.unrestrictedEvidence,
  });

  final List<EligibilityCondition> conditions;
  final List<String> unresolvedEvidence;
  final bool extractionComplete;
  final bool explicitlyUnrestricted;
  final String? unrestrictedEvidence;

  factory Eligibility.fromJson(Map<String, dynamic> m) => Eligibility(
    conditions: [
      for (final c in m['conditions'] as List)
        EligibilityCondition(field: c['field'] as String, evidence: c['evidence'] as String),
    ],
    unresolvedEvidence: [for (final u in m['unresolved_conditions'] as List) u['evidence'] as String],
    extractionComplete: m['extraction_complete'] as bool,
    explicitlyUnrestricted: m['explicitly_unrestricted'] as bool,
    unrestrictedEvidence: m['unrestricted_evidence'] as String?,
  );
}

class ActivityPeriod {
  const ActivityPeriod({required this.start, required this.end, required this.evidence});

  final DateInfo? start;
  final DateInfo? end;
  final String evidence;

  static ActivityPeriod? fromJson(Object? json) {
    if (json == null) return null;
    final m = json as Map<String, dynamic>;
    return ActivityPeriod(
      start: DateInfo.fromJson(m['start']),
      end: DateInfo.fromJson(m['end']),
      evidence: m['evidence'] as String,
    );
  }
}

class Notice {
  const Notice({
    required this.summary,
    required this.description,
    required this.applicationStart,
    required this.activityPeriod,
    required this.eligibility,
    required this.lastVerifiedAt,
    this.sourceId,
  });

  final NoticeSummary summary;

  /// 수집한 게시판 (예: mjc_www_notice). 모르면 null.
  final String? sourceId;

  /// 검증된 요약. 없으면 null.
  final String? description;
  final DateInfo? applicationStart;
  final ActivityPeriod? activityPeriod;
  final Eligibility eligibility;
  final DateTime? lastVerifiedAt;

  factory Notice.fromJson(Map<String, dynamic> m) => Notice(
    summary: NoticeSummary.fromJson(m),
    description: m['summary'] as String?,
    applicationStart: DateInfo.fromJson(m['application_start']),
    activityPeriod: ActivityPeriod.fromJson(m['activity_period']),
    eligibility: Eligibility.fromJson(m['eligibility'] as Map<String, dynamic>),
    lastVerifiedAt: m['last_verified_at'] == null ? null : DateTime.parse(m['last_verified_at'] as String),
    sourceId: m['source_id'] as String?,
  );
}

/// 조건별 비교 결과 (recommendation_item.condition_result). 서버가 판정한 값을 표시만 한다.
class ConditionResult {
  const ConditionResult({required this.field, required this.status, required this.evidence, this.unknownReason});

  final String field;

  /// met / not_met / unknown
  final String status;
  final String evidence;

  /// profile_missing / condition_unresolved / extraction_incomplete, 판정됐으면 null
  final String? unknownReason;

  factory ConditionResult.fromJson(Map<String, dynamic> m) => ConditionResult(
    field: m['field'] as String,
    status: m['status'] as String,
    evidence: m['evidence'] as String,
    unknownReason: m['unknown_reason'] as String?,
  );
}

class Recommendation {
  const Recommendation({
    required this.noticeId,
    required this.score,
    required this.eligibilityStatus,
    required this.reasonCodes,
    this.conditionResults = const [],
  });

  final String noticeId;

  /// 내부 순위용. 표시하지 않는다.
  final double? score;

  /// met / not_met / needs_check
  final String eligibilityStatus;
  final List<String> reasonCodes;
  final List<ConditionResult> conditionResults;

  factory Recommendation.fromJson(Map<String, dynamic> m) => Recommendation(
    noticeId: m['notice_id'] as String,
    score: (m['score'] as num?)?.toDouble(),
    eligibilityStatus: m['eligibility_status'] as String,
    reasonCodes: [for (final r in m['reason_codes'] as List) r as String],
    conditionResults: [
      for (final c in (m['condition_results'] as List?) ?? const [])
        ConditionResult.fromJson(c as Map<String, dynamic>),
    ],
  );
}

class RecommendationEntry {
  const RecommendationEntry({required this.recommendation, required this.notice});

  final Recommendation recommendation;
  final NoticeSummary notice;
}

class RecommendationList {
  const RecommendationList({required this.mode, required this.items, required this.generatedAt});

  /// personalized / latest
  final String mode;
  final List<RecommendationEntry> items;
  final DateTime generatedAt;

  bool get personalized => mode == 'personalized';

  factory RecommendationList.fromJson(Map<String, dynamic> m) => RecommendationList(
    mode: m['mode'] as String,
    items: [
      for (final i in m['items'] as List)
        RecommendationEntry(
          recommendation: Recommendation.fromJson(i['recommendation'] as Map<String, dynamic>),
          notice: NoticeSummary.fromJson(i['notice'] as Map<String, dynamic>),
        ),
    ],
    generatedAt: DateTime.parse(m['generated_at'] as String),
  );
}

/// UserProfile (contracts/user_profile.schema.json). 미입력은 null 또는 빈 목록.
class UserProfile {
  const UserProfile({
    this.universityId,
    this.majorId,
    this.grade,
    this.enrollmentStatus,
    this.interestIds = const [],
    this.targetRoleIds = const [],
  });

  final String? universityId;
  final String? majorId;
  final int? grade;

  /// enrolled / on_leave / graduated
  final String? enrollmentStatus;
  final List<String> interestIds;
  final List<String> targetRoleIds;

  /// 관심사·직무·전공 중 하나라도 있으면 맞춤 추천 대상 (서버 규칙과 같음)
  bool get hasPersonalInput => majorId != null || interestIds.isNotEmpty || targetRoleIds.isNotEmpty;

  factory UserProfile.fromJson(Map<String, dynamic> m) => UserProfile(
    universityId: m['university_id'] as String?,
    majorId: m['major_id'] as String?,
    grade: m['grade'] as int?,
    enrollmentStatus: m['enrollment_status'] as String?,
    interestIds: [for (final i in m['interest_ids'] as List) i as String],
    targetRoleIds: [for (final r in m['target_role_ids'] as List) r as String],
  );

  /// PUT /v1/profile 본문. updated_at은 서버가 정한다.
  Map<String, dynamic> toJson() => {
    'university_id': universityId,
    'major_id': majorId,
    'grade': grade,
    'enrollment_status': enrollmentStatus,
    'interest_ids': interestIds,
    'target_role_ids': targetRoleIds,
  };
}

class SavedNotice {
  const SavedNotice({
    required this.noticeId,
    required this.savedAt,
    required this.savedNoticeVersion,
    required this.savedDeadlineSnapshot,
  });

  final String noticeId;
  final DateTime savedAt;
  final int savedNoticeVersion;

  /// 저장 당시 마감. 변경 안내용이며 최신 마감을 덮어쓰지 않는다 (SPEC §5).
  final DateInfo? savedDeadlineSnapshot;

  factory SavedNotice.fromJson(Map<String, dynamic> m) => SavedNotice(
    noticeId: m['notice_id'] as String,
    savedAt: DateTime.parse(m['saved_at'] as String),
    savedNoticeVersion: m['saved_notice_version'] as int,
    savedDeadlineSnapshot: DateInfo.fromJson(m['saved_deadline_snapshot']),
  );
}

class SavedEntry {
  const SavedEntry({required this.saved, required this.notice});

  final SavedNotice saved;
  final NoticeSummary notice;

  /// 저장 이후 마감 날짜·시각이 바뀌었는지
  bool get deadlineChanged {
    final before = saved.savedDeadlineSnapshot;
    final now = notice.applicationDeadline;
    if (before == null && now == null) return false;
    return before?.date != now?.date || before?.time != now?.time;
  }
}

class DictionaryItem {
  const DictionaryItem(this.id, this.name);

  final String id;
  final String name;
}
