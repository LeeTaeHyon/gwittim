import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'repository.dart';

/// 지원 건: 저장한 공고 한 건의 신청 진행 상태 (care-loop-impl-spec §2, D-052).
///
/// 기기에만 둔다. 날짜·공고 변경으로 바뀌는 상태(마감 지남·모집 끝남·삭제됨)는 저장하지 않고
/// [effectiveState]가 읽을 때 계산한다. 그래서 마감이 늦춰지면 저절로 되살아난다.
enum CaseState { saved, preparing, applied, skipped, missed, closed, removed }

/// 사용자가 바꿀 수 있는 상태. 기기에 남는 것은 이 넷뿐이다.
const _userStates = {CaseState.saved, CaseState.preparing, CaseState.applied, CaseState.skipped};

class ApplicationCase {
  const ApplicationCase({
    required this.noticeId,
    required this.state,
    required this.changedAt,
    this.previous,
    this.seenDeadline,
    this.emphasizedOn,
    this.eligibilityStatus,
    this.eligibilityAt,
  });

  final String noticeId;

  /// 사용자 전이로 정해진 상태(saved·preparing·applied·skipped). 화면은 [effectiveState]를 쓴다.
  final CaseState state;

  /// 되돌리기용 바로 전 상태(saved·preparing·applied·skipped 중).
  final CaseState? previous;

  /// 기기 시각.
  final DateTime changedAt;

  /// 리포트를 연 때의 마감 'YYYY-MM-DD HH:MM'(시각 없으면 날짜만, 마감 없으면 '').
  final String? seenDeadline;

  /// 마지막으로 강조(말풍선 건수·브리핑 카드)에 들어간 날 'YYYY-MM-DD'.
  final String? emphasizedOn;

  /// 서버 판정 met / needs_check / not_met. 모르면 null (팀장 결정 2026-11-24).
  final String? eligibilityStatus;

  /// 그 판정을 받은 시각(기기 시각).
  final DateTime? eligibilityAt;

  ApplicationCase copyWith({
    CaseState? state,
    CaseState? previous,
    bool clearPrevious = false,
    DateTime? changedAt,
    String? seenDeadline,
    String? emphasizedOn,
    String? eligibilityStatus,
    DateTime? eligibilityAt,
    bool clearEligibility = false,
  }) => ApplicationCase(
    noticeId: noticeId,
    state: state ?? this.state,
    previous: clearPrevious ? null : (previous ?? this.previous),
    changedAt: changedAt ?? this.changedAt,
    seenDeadline: seenDeadline ?? this.seenDeadline,
    emphasizedOn: emphasizedOn ?? this.emphasizedOn,
    eligibilityStatus: clearEligibility ? null : (eligibilityStatus ?? this.eligibilityStatus),
    eligibilityAt: clearEligibility ? null : (eligibilityAt ?? this.eligibilityAt),
  );

  Map<String, dynamic> toJson() => {
    'state': state.name,
    if (previous != null) 'previous': previous!.name,
    'changed_at': changedAt.toIso8601String(),
    if (seenDeadline != null) 'seen_deadline': seenDeadline,
    if (emphasizedOn != null) 'emphasized_on': emphasizedOn,
    if (eligibilityStatus != null) 'eligibility_status': eligibilityStatus,
    if (eligibilityAt != null) 'eligibility_at': eligibilityAt!.toIso8601String(),
  };

  /// 알 수 없는 값이 있으면 null(그 건은 버린다).
  static ApplicationCase? fromJson(String noticeId, Object? json) {
    if (json is! Map) return null;
    final state = _userState(json['state']);
    final changedAt = DateTime.tryParse('${json['changed_at']}');
    if (state == null || changedAt == null) return null;
    return ApplicationCase(
      noticeId: noticeId,
      state: state,
      previous: _userState(json['previous']),
      changedAt: changedAt,
      seenDeadline: json['seen_deadline'] as String?,
      emphasizedOn: json['emphasized_on'] as String?,
      eligibilityStatus: json['eligibility_status'] as String?,
      eligibilityAt: json['eligibility_at'] == null ? null : DateTime.tryParse('${json['eligibility_at']}'),
    );
  }

  static CaseState? _userState(Object? name) {
    for (final s in _userStates) {
      if (s.name == name) return s;
    }
    return null;
  }
}

/// 끝난 상태: 리마인드가 멈추고 다음 할 일이 없다.
bool isEnded(CaseState s) => s != CaseState.saved && s != CaseState.preparing;

/// 지금 마감이 지났는가 (care-loop-impl-spec §3.3).
///
/// - 시각과 시간대가 모두 있으면 그 시각. 지금 출처의 시간대는 Asia/Seoul뿐이라 UTC+9로 바꿔 비교한다.
///   다른 시간대는 아직 없어 날짜로만 비교한다.
/// - 시각만 있고 시간대가 null(교외)이거나 날짜만이면 날짜로만: 마감일 다음 날 0시(기기 시각)에 지남.
bool deadlinePassed(DateInfo deadline, DateTime now) {
  final at = deadlineInstant(deadline);
  if (at != null) return !now.toUtc().isBefore(at);
  final next = DateTime(deadline.day.year, deadline.day.month, deadline.day.day + 1);
  return !now.isBefore(next);
}

/// 시각까지 비교할 수 있는 마감의 순간(UTC). 날짜로만 비교하는 마감이면 null.
DateTime? deadlineInstant(DateInfo d) {
  if (!d.hasTime || d.timezone != 'Asia/Seoul') return null;
  final parts = d.time!.split(':');
  final day = d.day;
  return DateTime.utc(
    day.year,
    day.month,
    day.day,
    int.parse(parts[0]),
    int.parse(parts[1]),
  ).subtract(const Duration(hours: 9));
}

/// 날짜·공고 변경을 반영한 지금 상태 (전이 표의 '날짜'·'공고 변경' 줄).
CaseState effectiveState(ApplicationCase c, NoticeSummary n, DateTime now) {
  if (n.lifecycleStatus == 'removed') return CaseState.removed;
  if (c.state == CaseState.applied || c.state == CaseState.skipped) return c.state;
  if (n.lifecycleStatus == 'closed') return CaseState.closed;
  final deadline = n.applicationDeadline;
  if (deadline != null && deadlinePassed(deadline, now)) return CaseState.missed;
  return c.state;
}

/// 마감을 'YYYY-MM-DD HH:MM'(시각 없으면 날짜만) 한 줄로. 마감이 없으면 ''.
String deadlineKey(DateInfo? d) => d == null ? '' : (d.hasTime ? '${d.date} ${d.time}' : d.date);

String _dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 지원 건 기록을 기기에 읽고 쓰는 곳.
abstract class CaseStorage {
  Future<Map<String, ApplicationCase>> load();
  Future<void> save(Map<String, ApplicationCase> cases);
}

class PrefsCaseStorage implements CaseStorage {
  static const key = 'application_cases';

  @override
  Future<Map<String, ApplicationCase>> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    if (raw == null) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    final out = <String, ApplicationCase>{};
    for (final e in decoded.entries) {
      final c = ApplicationCase.fromJson('${e.key}', e.value);
      if (c != null) out[c.noticeId] = c;
    }
    return out;
  }

  @override
  Future<void> save(Map<String, ApplicationCase> cases) async => (await SharedPreferences.getInstance()).setString(
    key,
    jsonEncode({for (final c in cases.values) c.noticeId: c.toJson()}),
  );
}

class MemoryCaseStorage implements CaseStorage {
  MemoryCaseStorage([Map<String, ApplicationCase>? initial]) : _cases = {...?initial};

  Map<String, ApplicationCase> _cases;
  Map<String, ApplicationCase> get saved => Map.unmodifiable(_cases);

  @override
  Future<Map<String, ApplicationCase>> load() async => {..._cases};

  @override
  Future<void> save(Map<String, ApplicationCase> cases) async => _cases = {...cases};
}

/// 앱 전체가 나눠 쓰는 지원 건 저장소. 한 곳에서 바꾸면 듣고 있는 화면이 바로 다시 그린다.
///
/// 읽기·쓰기 실패는 앱을 멈추지 않는다: 읽기가 실패하면 빈 상태로 시작하고, 쓰기가 실패하면
/// 이번 실행 동안만 기억한다(`major_picks`와 같은 방식).
class ApplicationCaseStore extends ChangeNotifier {
  ApplicationCaseStore({CaseStorage? storage, DateTime Function()? now})
    : _storage = storage ?? PrefsCaseStorage(),
      _now = now ?? DateTime.now;

  final CaseStorage _storage;
  final DateTime Function() _now;
  Map<String, ApplicationCase> _cases = {};
  Future<void>? _loading;

  /// 기기 기록을 한 번 읽는다. 여러 번 불러도 한 번만 읽는다.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final loaded = await _storage.load();
      // 읽는 동안 생긴 변경(저장 등)을 덮지 않는다
      _cases = {...loaded, ..._cases};
    } catch (_) {
      // 기기 저장소를 못 읽으면 빈 상태로 시작한다
    }
    if (!_disposed) notifyListeners();
  }

  ApplicationCase? operator [](String noticeId) => _cases[noticeId];
  Iterable<ApplicationCase> get all => _cases.values;

  /// 기기 쓰기는 순서대로 하되 기다리지 않는다. 화면(저장 알림·로그아웃)이 기기 저장소 때문에 멈추지 않게.
  Future<void> _writes = Future.value();

  /// 앞서 시작한 기기 쓰기가 모두 끝날 때까지(테스트용).
  Future<void> get flushed => _writes;

  /// 탈퇴 뒤처럼 앱 본체가 먼저 사라진 다음에 지워도 오류가 나지 않게 한다.
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _put(Map<String, ApplicationCase> next) async {
    _cases = next;
    if (!_disposed) notifyListeners();
    _write(next);
  }

  void _write(Map<String, ApplicationCase> snapshot) {
    _writes = _writes.then((_) => _storage.save(snapshot)).then<void>(
      (_) {},
      onError: (Object _) {
        // 쓰기 실패: 이번 실행 동안만 기억한다
      },
    );
  }

  /// 저장(saveNotice) 성공 뒤. 이미 기록이 있으면 판정만 채운다.
  Future<void> recordSaved(String noticeId, {String? eligibilityStatus}) async {
    final now = _now();
    final old = _cases[noticeId];
    final c = old == null
        ? ApplicationCase(
            noticeId: noticeId,
            state: CaseState.saved,
            changedAt: now,
            eligibilityStatus: eligibilityStatus,
            eligibilityAt: eligibilityStatus == null ? null : now,
          )
        : (eligibilityStatus == null ? old : old.copyWith(eligibilityStatus: eligibilityStatus, eligibilityAt: now));
    await _put({..._cases, noticeId: c});
  }

  /// 저장 취소(deleteSaved) 성공 뒤, 또는 '목록에서 지우기'.
  Future<void> forget(String noticeId) async {
    if (!_cases.containsKey(noticeId)) return;
    await _put({..._cases}..remove(noticeId));
  }

  /// '준비 시작'. saved에서만.
  Future<bool> startPreparing(String noticeId) => _move(noticeId, {CaseState.saved}, CaseState.preparing);

  /// '신청함'. saved·preparing에서만.
  Future<bool> markApplied(String noticeId) =>
      _move(noticeId, {CaseState.saved, CaseState.preparing}, CaseState.applied);

  /// '이번엔 안 함'. saved·preparing에서만.
  Future<bool> markSkipped(String noticeId) =>
      _move(noticeId, {CaseState.saved, CaseState.preparing}, CaseState.skipped);

  /// '되돌리기'. applied·skipped에서 바로 전 상태로. 바로 전 상태가 없으면 saved.
  Future<bool> undo(String noticeId) async {
    final c = _cases[noticeId];
    if (c == null || (c.state != CaseState.applied && c.state != CaseState.skipped)) return false;
    await _put({
      ..._cases,
      noticeId: c.copyWith(state: c.previous ?? CaseState.saved, clearPrevious: true, changedAt: _now()),
    });
    return true;
  }

  Future<bool> _move(String noticeId, Set<CaseState> from, CaseState to) async {
    final c = _cases[noticeId];
    if (c == null || !from.contains(c.state)) return false;
    await _put({..._cases, noticeId: c.copyWith(state: to, previous: c.state, changedAt: _now())});
    return true;
  }

  /// 리포트를 연 때의 마감을 기록한다(마감 변경 표시를 한 번만 보이기).
  Future<void> markDeadlineSeen(String noticeId, DateInfo? deadline) async {
    final c = _cases[noticeId];
    final key = deadlineKey(deadline);
    if (c == null || c.seenDeadline == key) return;
    await _put({..._cases, noticeId: c.copyWith(seenDeadline: key)});
  }

  /// 오늘 강조(말풍선 건수·브리핑 카드)에 들어간 지원 건을 기록한다.
  Future<void> markEmphasized(Iterable<String> noticeIds, DateTime day) async {
    final key = _dayKey(day);
    final next = {..._cases};
    var changed = false;
    for (final id in noticeIds) {
      final c = next[id];
      if (c == null || c.emphasizedOn == key) continue;
      next[id] = c.copyWith(emphasizedOn: key);
      changed = true;
    }
    if (changed) await _put(next);
  }

  /// 그날 이미 강조된 지원 건인가.
  bool emphasizedOn(String noticeId, DateTime day) => _cases[noticeId]?.emphasizedOn == _dayKey(day);

  /// 추천 목록을 받을 때마다: 목록에 있는 지원 건의 판정 값과 시각을 갱신한다.
  Future<void> updateEligibility(RecommendationList list) async {
    final now = _now();
    final next = {..._cases};
    var changed = false;
    for (final e in list.items) {
      final c = next[e.notice.noticeId];
      if (c == null || c.eligibilityStatus == e.recommendation.eligibilityStatus) continue;
      next[c.noticeId] = c.copyWith(eligibilityStatus: e.recommendation.eligibilityStatus, eligibilityAt: now);
      changed = true;
    }
    if (changed) await _put(next);
  }

  /// 프로필이 바뀌면: 모든 지원 건의 판정 값을 지운다. 새 추천 목록이 다시 채운다.
  Future<void> clearEligibility() async {
    if (_cases.values.every((c) => c.eligibilityStatus == null && c.eligibilityAt == null)) return;
    await _put({for (final c in _cases.values) c.noticeId: c.copyWith(clearEligibility: true)});
  }

  /// 저장 목록을 받은 뒤: 목록에 없는 공고의 기록을 지운다(다른 기기에서 저장 취소한 경우).
  Future<void> pruneTo(Iterable<String> savedIds) async {
    final keep = savedIds.toSet();
    if (_cases.keys.every(keep.contains)) return;
    await _put({
      for (final c in _cases.values)
        if (keep.contains(c.noticeId)) c.noticeId: c,
    });
  }

  /// 탈퇴·로그아웃 때 모두 지운다.
  Future<void> clearAll() async {
    // 기기 저장소를 못 쓰면 다음 실행 때 남는다
    await _put({});
  }
}

/// 저장·저장 취소·추천 목록·프로필 변경을 지원 건 저장소에 한 곳에서 반영하는 저장소 (care-loop-impl-spec §2).
///
/// 화면은 이 저장소를 쓰기만 하면 되고, 지원 건 기록을 따로 고치지 않는다.
/// - 저장할 때의 판정: 그 공고가 마지막으로 받은 추천 목록에 있으면 그 판정, 없으면 null
class CaseTrackingRepository implements NoticeRepository, WrappingRepository {
  CaseTrackingRepository(this._inner, this.cases);

  final NoticeRepository _inner;
  final ApplicationCaseStore cases;
  final _lastStatus = <String, String>{};

  @override
  NoticeRepository get inner => _inner;

  void _remember(RecommendationList list) {
    for (final e in list.items) {
      _lastStatus[e.notice.noticeId] = e.recommendation.eligibilityStatus;
    }
  }

  @override
  Future<RecommendationList> listRecommendations() async {
    final list = await _inner.listRecommendations();
    _remember(list);
    await cases.updateEligibility(list);
    return list;
  }

  @override
  Future<RecommendationList> searchNotices({String query = '', String? category}) async {
    final list = await _inner.searchNotices(query: query, category: category);
    _remember(list);
    await cases.updateEligibility(list);
    return list;
  }

  @override
  Future<List<SavedEntry>> listSaved() async {
    final saved = await _inner.listSaved();
    await cases.pruneTo(saved.map((s) => s.notice.noticeId));
    return saved;
  }

  @override
  Future<void> saveNotice(String noticeId) async {
    await _inner.saveNotice(noticeId);
    await cases.recordSaved(noticeId, eligibilityStatus: _lastStatus[noticeId]);
  }

  @override
  Future<void> deleteSaved(String noticeId) async {
    await _inner.deleteSaved(noticeId);
    await cases.forget(noticeId);
  }

  /// 판정에 쓰이는 프로필 값(학교·학과·학년·재학 상태)이 바뀔 때만 판정을 지운다.
  /// AI 전송 동의 기록만 바뀌는 저장(같은 경로를 씀)은 판정을 건드리지 않는다.
  @override
  Future<void> updateProfile(UserProfile profile) async {
    UserProfile? before;
    try {
      before = await _inner.getProfile();
    } catch (_) {
      before = null; // 이전 값을 모르면 바뀐 것으로 본다
    }
    await _inner.updateProfile(profile);
    if (before != null && _sameForEligibility(before, profile)) return;
    _lastStatus.clear();
    await cases.clearEligibility();
  }

  static bool _sameForEligibility(UserProfile a, UserProfile b) =>
      a.universityId == b.universityId &&
      a.majorId == b.majorId &&
      a.grade == b.grade &&
      a.enrollmentStatus == b.enrollmentStatus;

  @override
  Future<void> deleteAccountData() async {
    await _inner.deleteAccountData();
    _lastStatus.clear();
    await cases.clearAll();
  }

  @override
  Future<Notice?> getNotice(String noticeId) => _inner.getNotice(noticeId);

  @override
  Future<Map<String, String>> categoryNames() => _inner.categoryNames();

  @override
  Future<UserProfile?> getProfile() => _inner.getProfile();

  @override
  Future<List<DictionaryItem>> dictionary(String name) => _inner.dictionary(name);

  @override
  Future<Map<String, List<String>>> majorInterests() => _inner.majorInterests();

  @override
  Future<AnalysisResponse> requestAnalysis({
    required String noticeId,
    required String requestId,
    AnalysisChips chips = const AnalysisChips(),
  }) => _inner.requestAnalysis(noticeId: noticeId, requestId: requestId, chips: chips);

  @override
  Future<ExternalSearchResult> requestExternalSearch({
    required String requestId,
    String? category,
    List<String> interests = const [],
    String? period,
    List<String> regions = const [],
    String query = '',
  }) => _inner.requestExternalSearch(
    requestId: requestId,
    category: category,
    interests: interests,
    period: period,
    regions: regions,
    query: query,
  );

  @override
  Future<AnalysisResponse?> getAnalysis(String noticeId) => _inner.getAnalysis(noticeId);

  @override
  Future<Credits> getCredits() => _inner.getCredits();
}

/// 화면이 지원 건 저장소를 찾는 곳. 저장소가 바뀌면 [of]로 찾은 화면이 다시 그린다.
class ApplicationCaseScope extends InheritedNotifier<ApplicationCaseStore> {
  const ApplicationCaseScope({super.key, required ApplicationCaseStore super.notifier, required super.child});

  static ApplicationCaseStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ApplicationCaseScope>()?.notifier;

  /// 그리기 밖(버튼 처리 등)에서 찾을 때. 다시 그리기를 걸지 않는다.
  static ApplicationCaseStore? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ApplicationCaseScope>()?.notifier;
}
