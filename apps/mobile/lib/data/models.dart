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
  /// 원문 링크. 웹 원문이 없는 카카오톡 알림톡은 null (D-019).
  final String? sourceUrl;

  /// 카카오톡 알림톡 공고. 웹 원문이 없는 출처는 알림톡뿐이다 (D-019).
  bool get isKakao => sourceUrl == null;
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
    sourceUrl: m['source_url'] as String?,
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
    this.preferredEvidence = const [],
  });

  final List<EligibilityCondition> conditions;
  final List<String> unresolvedEvidence;

  /// unresolvedEvidence 중 우대 사항(note '우대 사항', D-015). 지원 자격이 아니라 갖추면 유리한 조건.
  final List<String> preferredEvidence;
  final bool extractionComplete;
  final bool explicitlyUnrestricted;
  final String? unrestrictedEvidence;

  factory Eligibility.fromJson(Map<String, dynamic> m) => Eligibility(
    conditions: [
      for (final c in m['conditions'] as List)
        EligibilityCondition(field: c['field'] as String, evidence: c['evidence'] as String),
    ],
    unresolvedEvidence: [for (final u in m['unresolved_conditions'] as List) u['evidence'] as String],
    preferredEvidence: [
      for (final u in m['unresolved_conditions'] as List)
        if (u['note'] == '우대 사항') u['evidence'] as String,
    ],
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
    this.applyUrl,
    this.relatedNotices = const [],
    this.bodyPreview = false,
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

  /// 알림톡 본문에 적힌 학교 사이트(신청·안내). 게시판 공고는 null (D-025).
  final String? applyUrl;

  /// 알림톡과 같은 행사를 안내하는 게시판 공고 (D-025).
  final List<({String noticeId, String title})> relatedNotices;

  /// 폰 알림으로만 받은 알림톡이라 본문 뒷부분이 빠졌을 수 있음 (D-040).
  final bool bodyPreview;

  factory Notice.fromJson(Map<String, dynamic> m) => Notice(
    summary: NoticeSummary.fromJson(m),
    description: m['summary'] as String?,
    applicationStart: DateInfo.fromJson(m['application_start']),
    activityPeriod: ActivityPeriod.fromJson(m['activity_period']),
    eligibility: Eligibility.fromJson(m['eligibility'] as Map<String, dynamic>),
    lastVerifiedAt: m['last_verified_at'] == null ? null : DateTime.parse(m['last_verified_at'] as String),
    sourceId: m['source_id'] as String?,
    applyUrl: m['apply_url'] as String?,
    relatedNotices: [
      for (final r in (m['related_notices'] as List?) ?? const [])
        (noticeId: r['notice_id'] as String, title: r['title'] as String),
    ],
    bodyPreview: m['body_preview'] as bool? ?? false,
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
    this.agentConsent,
  });

  final String? universityId;
  final String? majorId;
  final int? grade;

  /// enrolled / on_leave / graduated
  final String? enrollmentStatus;
  final List<String> interestIds;
  final List<String> targetRoleIds;

  /// AI 상세 분석 첫 사용 동의 기록. 없으면 동의하지 않은 것이다.
  final AgentConsent? agentConsent;

  /// 관심사·직무·전공 중 하나라도 있으면 맞춤 추천 대상 (서버 규칙과 같음)
  bool get hasPersonalInput => majorId != null || interestIds.isNotEmpty || targetRoleIds.isNotEmpty;

  factory UserProfile.fromJson(Map<String, dynamic> m) => UserProfile(
    universityId: m['university_id'] as String?,
    majorId: m['major_id'] as String?,
    grade: m['grade'] as int?,
    enrollmentStatus: m['enrollment_status'] as String?,
    interestIds: [for (final i in m['interest_ids'] as List) i as String],
    targetRoleIds: [for (final r in m['target_role_ids'] as List) r as String],
    agentConsent: m['agent_consent'] == null
        ? null
        : AgentConsent.fromJson(m['agent_consent'] as Map<String, dynamic>),
  );

  /// 동의 기록만 바꾼 사본. [consent]가 null이면 철회다.
  UserProfile withAgentConsent(AgentConsent? consent) => UserProfile(
    universityId: universityId,
    majorId: majorId,
    grade: grade,
    enrollmentStatus: enrollmentStatus,
    interestIds: interestIds,
    targetRoleIds: targetRoleIds,
    agentConsent: consent,
  );

  /// PUT /v1/profile 본문. updated_at은 서버가 정한다.
  /// agent_consent는 있을 때만 보낸다. 빠지면 서버는 철회로 본다.
  Map<String, dynamic> toJson() => {
    'university_id': universityId,
    'major_id': majorId,
    'grade': grade,
    'enrollment_status': enrollmentStatus,
    'interest_ids': interestIds,
    'target_role_ids': targetRoleIds,
    'agent_consent': ?agentConsent?.toJson(),
  };
}

/// 외부 AI 전송 동의 기록 (user_profile.schema.json agent_consent).
/// 문구가 바뀌어 [agentConsentVersion]이 오르면 이전 기록은 동의로 보지 않는다.
class AgentConsent {
  const AgentConsent({required this.version, required this.agreedAt});

  final String version;
  final DateTime agreedAt;

  factory AgentConsent.fromJson(Map<String, dynamic> m) =>
      AgentConsent(version: m['version'] as String, agreedAt: DateTime.parse(m['agreed_at'] as String));

  /// agreed_at은 UTC 'Z' 형식. 서버가 서버 시각으로 덮어쓴다.
  Map<String, dynamic> toJson() => {'version': version, 'agreed_at': agreedAt.toUtc().toIso8601String()};
}

/// 지금 동의 문구의 버전 (docs/agent-privacy-spec.md §5.1)
const agentConsentVersion = '2026-11-22'; // D-044 받는 곳 DeepSeek로 변경, 다시 동의

extension UserProfileConsent on UserProfile? {
  /// 지금 문구에 동의한 기록이 있는지
  bool get hasAgentConsent => this?.agentConsent?.version == agentConsentVersion;
}

/// 상세 분석을 요청할 때만 묻는 선택 값 (analysis_request.schema.json chips). 모두 선택이다.
class AnalysisChips {
  const AnalysisChips({this.experience = const [], this.period, this.regions = const []});

  /// 해 본 것 (여러 개). none_yet은 단독
  final List<String> experience;

  /// 가능한 시기 (하나)
  final String? period;

  /// 갈 수 있는 지역 (여러 개). any는 단독
  final List<String> regions;

  bool get isEmpty => experience.isEmpty && period == null && regions.isEmpty;

  /// 비어 있는 질문은 키를 보내지 않는다. 모두 비면 빈 객체('건너뛰고 분석').
  Map<String, dynamic> toJson() => {
    if (experience.isNotEmpty) 'experience': experience,
    'period': ?period,
    if (regions.isNotEmpty) 'regions': regions,
  };

  factory AnalysisChips.fromJson(Map<String, dynamic> m) => AnalysisChips(
    experience: [for (final e in (m['experience'] as List?) ?? const []) e as String],
    period: m['period'] as String?,
    regions: [for (final e in (m['regions'] as List?) ?? const []) e as String],
  );
}

/// 상세 분석 리포트 네 칸. 서버가 준 글을 그대로 보인다 (analysis_response.schema.json).
class AnalysisReport {
  const AnalysisReport({required this.fit, required this.eligibility, required this.todo, required this.skills});

  /// 나에게 맞는 점·안 맞는 점
  final String fit;

  /// 지원 자격
  final String eligibility;

  /// 지원 전 할 일
  final String todo;

  /// 필요한 역량
  final String skills;

  factory AnalysisReport.fromJson(Map<String, dynamic> m) => AnalysisReport(
    fit: m['fit'] as String,
    eligibility: m['eligibility'] as String,
    todo: m['todo'] as String,
    skills: m['skills'] as String,
  );
}

class AnalysisResponse {
  const AnalysisResponse({
    required this.noticeId,
    required this.report,
    required this.expiresAt,
    required this.fromCache,
  });

  final String noticeId;
  final AnalysisReport report;

  /// 저장본 삭제 기준 시각
  final DateTime expiresAt;

  /// true면 저장본이며 AI를 새로 부르지 않은 응답
  final bool fromCache;

  factory AnalysisResponse.fromJson(Map<String, dynamic> m) => AnalysisResponse(
    noticeId: m['notice_id'] as String,
    report: AnalysisReport.fromJson(m['report'] as Map<String, dynamic>),
    expiresAt: DateTime.parse(m['expires_at'] as String),
    fromCache: m['from_cache'] as bool,
  );
}

/// 크레딧 사용 내역 한 줄 (credits.schema.json)
class CreditEntry {
  const CreditEntry({required this.kind, required this.amount, required this.at, required this.ref});

  /// signup / daily / detail_analysis / external_search
  final String kind;

  /// 충전은 +, 사용은 −
  final int amount;
  final DateTime at;

  /// 사용 내역이 가리키는 id (상세 분석은 공고 id). 충전은 null
  final String? ref;

  factory CreditEntry.fromJson(Map<String, dynamic> m) => CreditEntry(
    kind: m['kind'] as String,
    amount: m['amount'] as int,
    at: DateTime.parse(m['at'] as String),
    ref: m['ref'] as String?,
  );
}

class Credits {
  const Credits({required this.balance, required this.nextRefillAt, required this.entries});

  /// 지금 쓸 수 있는 개수 (0~5)
  final int balance;

  /// 다음 충전 시각. 최대 보유면 null
  final DateTime? nextRefillAt;

  /// 최근 90일, 최신순
  final List<CreditEntry> entries;

  static const max = 5;

  /// 이 공고의 상세 분석을 마지막으로 받은 시각. 내역에 없으면 null (90일이 지났거나 저장본만 있는 경우)
  DateTime? analysisReceivedAt(String noticeId) {
    DateTime? latest;
    for (final e in entries) {
      if (e.kind == 'detail_analysis' && e.ref == noticeId && (latest == null || e.at.isAfter(latest))) {
        latest = e.at;
      }
    }
    return latest;
  }

  factory Credits.fromJson(Map<String, dynamic> m) => Credits(
    balance: m['balance'] as int,
    nextRefillAt: m['next_refill_at'] == null ? null : DateTime.parse(m['next_refill_at'] as String),
    entries: [for (final e in m['entries'] as List) CreditEntry.fromJson(e as Map<String, dynamic>)],
  );
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
  const DictionaryItem(this.id, this.name, {this.universityId});

  final String id;
  final String name;

  /// 학과 사전에서 학과가 속한 학교 코드. 다른 사전은 null.
  final String? universityId;
}
