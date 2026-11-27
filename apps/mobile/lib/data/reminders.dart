import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/case_view.dart';
import 'application_case.dart';
import 'models.dart';

/// 기기 안 마감 알림 (report-reminder-spec §5.2, D-061).
///
/// 서버 푸시가 아니라 이 기기가 알림을 예약한다. 진행 중 지원 건(저장·준비 중)만 대상이고,
/// 정확한 알람 권한은 쓰지 않아(inexact) 몇 분 늦을 수 있다. 마감 시각을 지어내지 않는다.

/// 알림이 울리는 시각(기기 시간대)
const reminderHour = 9;

/// 마감 시각이 이 시각 이전이면 마감 당일 09:00이 이미 늦으므로 전날 [eveHour]시에 알린다
const earlyDeadlineBefore = '10:00';
const eveHour = 20;

/// 예약하는 최대 건수(앞날부터). 하루 최대 2번이라 60건이면 한 달 치다
const maxScheduled = 60;

enum ReminderKind { start, twoDays, due, dueEve }

/// 알림을 만들 지원 건 한 건의 자료
class ReminderInput {
  const ReminderInput({required this.notice, this.applicationStart, this.todoLeft});

  final NoticeSummary notice;

  /// 지원 건에 복사해 둔 신청 시작. 모르면 null
  final DateInfo? applicationStart;

  /// 남은 할 일 수. 상세 분석이 없으면 null
  final int? todoLeft;
}

/// 예약할 알림 한 건. [payload]는 한 공고면 공고 id, 묶음이면 '' (누르면 저장함으로).
class PlannedReminder {
  const PlannedReminder({required this.at, required this.title, required this.body, required this.payload});

  final DateTime at;
  final String title;
  final String body;
  final String payload;

  @override
  bool operator ==(Object other) =>
      other is PlannedReminder &&
      other.at == at &&
      other.title == title &&
      other.body == body &&
      other.payload == payload;

  @override
  int get hashCode => Object.hash(at, title, body, payload);

  @override
  String toString() => 'PlannedReminder($at, $title, $body)';
}

class _Event {
  const _Event(this.at, this.kind, this.input);

  final DateTime at;
  final ReminderKind kind;
  final ReminderInput input;
}

DateTime _on(DateInfo d, int dayOffset, int hour) => DateTime(d.day.year, d.day.month, d.day.day + dayOffset, hour);

const _kindLabel = {
  ReminderKind.start: '오늘 신청 시작',
  ReminderKind.twoDays: '마감 2일 전',
  ReminderKind.due: '오늘 마감',
  ReminderKind.dueEve: '내일 마감',
};

/// 지금 예약해야 할 알림 전체. 진행 중인 지원 건만 [inputs]로 넘긴다(끝난 건·지난 마감은 호출하는 쪽이 거른다).
///
/// | 언제 | 시각 | 문구 |
/// | 신청 시작 당일 | 09:00 | 오늘 신청 시작 |
/// | 마감 2일 전 | 09:00 | 마감 2일 전 · 할 일 N개 남음 |
/// | 마감 당일 | 09:00(마감 시각이 10:00 이전이면 전날 20:00) | 오늘 18:00 마감 / 오늘 마감 · 시각 미상 |
///
/// 같은 시각이면 한 알림으로 묶는다. 시각이 하루 두 개(09:00·20:00)뿐이라 하루 최대 2번이다.
List<PlannedReminder> planReminders(Iterable<ReminderInput> inputs, DateTime now) {
  final events = <_Event>[];
  for (final input in inputs) {
    final start = input.applicationStart;
    if (start != null) events.add(_Event(_on(start, 0, reminderHour), ReminderKind.start, input));
    final deadline = input.notice.applicationDeadline;
    if (deadline != null && !deadlinePassed(deadline, now)) {
      events.add(_Event(_on(deadline, -2, reminderHour), ReminderKind.twoDays, input));
      final early = deadline.hasTime && deadline.time!.compareTo(earlyDeadlineBefore) < 0;
      events.add(
        early
            ? _Event(_on(deadline, -1, eveHour), ReminderKind.dueEve, input)
            : _Event(_on(deadline, 0, reminderHour), ReminderKind.due, input),
      );
    }
  }
  final byTime = <DateTime, List<_Event>>{};
  for (final e in events) {
    if (!e.at.isAfter(now)) continue;
    (byTime[e.at] ??= []).add(e);
  }
  final times = byTime.keys.toList()..sort();
  final out = <PlannedReminder>[];
  for (final at in times.take(maxScheduled)) {
    out.add(_merge(at, byTime[at]!));
  }
  return out;
}

String _body(_Event e) => switch (e.kind) {
  ReminderKind.start => '오늘 신청 시작',
  ReminderKind.twoDays => [
    '마감 2일 전',
    if ((e.input.todoLeft ?? 0) > 0) '할 일 ${e.input.todoLeft}개 남음',
  ].join(' · '),
  // 마감 문구는 앱 안 남은 날 문구와 같은 함수(care-loop-impl-spec §3.3). 울리는 시각 기준으로 만든다
  ReminderKind.due || ReminderKind.dueEve => remainingText(e.input.notice, e.at),
};

PlannedReminder _merge(DateTime at, List<_Event> group) {
  // 같은 공고의 여러 사건(예: 신청 시작과 마감 2일 전이 같은 날)은 한 줄로
  final byNotice = <String, List<_Event>>{};
  for (final e in group) {
    (byNotice[e.input.notice.noticeId] ??= []).add(e);
  }
  final ids = byNotice.keys.toList()..sort((a, b) => byNotice[a]!.first.input.notice.title.compareTo(byNotice[b]!.first.input.notice.title));
  if (ids.length == 1) {
    final events = byNotice[ids.first]!..sort((a, b) => a.kind.index.compareTo(b.kind.index));
    return PlannedReminder(
      at: at,
      title: events.first.input.notice.title,
      body: events.map(_body).join(' · '),
      payload: ids.first,
    );
  }
  // 묶음: 같은 종류면 제목에 종류를, 섞이면 종류별 건수를 본문에
  final kinds = <ReminderKind, int>{};
  for (final id in ids) {
    for (final k in {for (final e in byNotice[id]!) e.kind}) {
      kinds[k] = (kinds[k] ?? 0) + 1;
    }
  }
  final titles = [for (final id in ids) byNotice[id]!.first.input.notice.title];
  final sameKind = kinds.length == 1;
  final shown = titles.take(2).join(' · ');
  return PlannedReminder(
    at: at,
    title: '저장한 공고 ${ids.length}건${sameKind ? ' ${_kindLabel[kinds.keys.first]}' : ''}',
    body: sameKind
        ? (titles.length > 2 ? '$shown 외 ${titles.length - 2}건' : shown)
        : [
            for (final k in ReminderKind.values)
              if (kinds[k] case final n?) '${_kindLabel[k]} $n건',
          ].join(' · '),
    payload: '',
  );
}

/// 기기 알림 예약기. 실제 구현은 flutter_local_notifications(local_notifier.dart), 시험은 가짜.
abstract class ReminderNotifier {
  /// 알림 표시 권한이 있는가. 권한을 물어볼 수 없는 기기는 true
  Future<bool> notificationsAllowed();

  /// 권한을 묻는다(Android 13+ 시스템 창). 허용하면 true
  Future<bool> requestPermission();

  /// 예약을 모두 지우고 [plan]대로 다시 예약한다. 빈 목록이면 모두 지우기만
  Future<void> replaceAll(List<PlannedReminder> plan);

  /// 알림을 눌렀을 때의 payload(공고 id, 묶음이면 '')
  Stream<String> get taps;

  /// 알림을 눌러 앱이 새로 열렸으면 그 payload. 아니면 null
  Future<String?> launchPayload();
}

/// 알림 켬·끔과 권한을 물었는지 기록하는 곳(기기 저장)
abstract class ReminderPrefs {
  Future<bool> enabled();
  Future<void> setEnabled(bool value);
  Future<bool> asked();
  Future<void> setAsked();
}

class PrefsReminderPrefs implements ReminderPrefs {
  static const enabledKey = 'reminder_enabled';
  static const askedKey = 'reminder_asked';

  @override
  Future<bool> enabled() async => (await SharedPreferences.getInstance()).getBool(enabledKey) ?? true;

  @override
  Future<void> setEnabled(bool value) async => (await SharedPreferences.getInstance()).setBool(enabledKey, value);

  @override
  Future<bool> asked() async => (await SharedPreferences.getInstance()).getBool(askedKey) ?? false;

  @override
  Future<void> setAsked() async => (await SharedPreferences.getInstance()).setBool(askedKey, true);
}

class MemoryReminderPrefs implements ReminderPrefs {
  MemoryReminderPrefs({this.enabledNow = true, this.askedNow = false});

  bool enabledNow;
  bool askedNow;

  @override
  Future<bool> enabled() async => enabledNow;

  @override
  Future<void> setEnabled(bool value) async => enabledNow = value;

  @override
  Future<bool> asked() async => askedNow;

  @override
  Future<void> setAsked() async => askedNow = true;
}

/// 지원 건·저장 목록이 바뀔 때마다 알림 예약을 다시 맞춘다 (report-reminder-spec §5.2).
///
/// 다시 맞추는 때: 앱을 열 때, 저장 목록을 새로 받을 때(마감 변경), 지원 건 상태·할 일이 바뀔 때, 켬·끔을 바꿀 때.
/// 끔이거나 권한이 없으면 예약은 0건이다. 권한은 처음 저장할 때 한 번 묻는다(앱 첫 실행이 아니다).
class ReminderService extends ChangeNotifier {
  ReminderService({required this.notifier, ReminderPrefs? prefs, DateTime Function()? clock})
    : prefs = prefs ?? PrefsReminderPrefs(),
      _clock = clock ?? DateTime.now;

  final ReminderNotifier notifier;
  final ReminderPrefs prefs;
  final DateTime Function() _clock;

  bool _enabled = true;
  bool _denied = false;
  bool _disposed = false;
  List<SavedEntry> _saved = const [];

  /// 저장 목록을 한 번이라도 받았는가. 받기 전에는 예약을 건드리지 않는다(앱을 막 열어 목록이 비어 있을 때 기존 예약을 지우지 않게)
  bool _savedKnown = false;
  ApplicationCaseStore? _cases;
  Future<void> _chain = Future.value();
  String? _lastSignature;

  /// 저장 목록을 새로 받는 함수(저장 직후·앱을 열 때 쓴다). GwittimApp이 넣는다.
  Future<List<SavedEntry>> Function()? savedLoader;

  /// 마감 알림 켬. 기본 켬(권한이 없으면 예약은 0건)
  bool get enabled => _enabled;

  /// 마지막 확인에서 기기 알림 권한이 없었는가(내 정보 줄 안내용)
  bool get permissionDenied => _denied;

  /// 알림 누름
  Stream<String> get taps => notifier.taps;
  Future<String?> launchPayload() => notifier.launchPayload();

  /// 앞서 시작한 예약 작업이 모두 끝날 때까지(테스트용)
  Future<void> get idle => _chain;

  /// 기기 설정을 읽고 처음 한 번 맞춘다.
  Future<void> load() async {
    try {
      _enabled = await prefs.enabled();
    } catch (_) {
      _enabled = true;
    }
    _notify();
    await _schedule();
  }

  /// 지원 건 기록이 바뀔 때마다 다시 맞춘다.
  void attach(ApplicationCaseStore cases) {
    _cases?.removeListener(_onCases);
    _cases = cases..addListener(_onCases);
  }

  void _onCases() => _schedule();

  @override
  void dispose() {
    _disposed = true;
    _cases?.removeListener(_onCases);
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 저장 목록을 새로 받았을 때(CaseTrackingRepository.listSaved)
  Future<void> onSavedList(List<SavedEntry> saved) {
    _saved = saved;
    _savedKnown = true;
    return _schedule();
  }

  /// 저장 목록을 다시 받아 맞춘다(앱을 열 때, 저장 직후). 받지 못하면 지금 목록으로
  Future<void> refresh() async {
    final load = savedLoader;
    if (load != null) {
      try {
        _saved = await load();
        _savedKnown = true;
      } catch (_) {
        // 목록을 못 받으면 마지막으로 받은 목록으로 맞춘다
      }
    }
    await _schedule();
  }

  /// 지금 목록 그대로 다시 맞춘다(앱이 앞으로 나왔을 때 등)
  Future<void> sync() => _schedule();

  /// 처음 공고를 저장한 직후: 권한을 한 번 묻고, 목록을 다시 받아 맞춘다. 거부하면 앱 안 표시만 남는다.
  Future<void> afterSave() async {
    if (_enabled) await _askOnce();
    await refresh();
  }

  Future<void> _askOnce() async {
    try {
      if (await prefs.asked()) return;
      await prefs.setAsked();
      if (await notifier.notificationsAllowed()) return;
      _denied = !await notifier.requestPermission();
      _notify();
    } catch (_) {
      // 권한 창을 못 띄워도 앱은 그대로 쓴다
    }
  }

  /// 내 정보의 켬·끔. 켤 때 권한이 없으면 권한을 묻는다. 끄면 예약을 모두 지운다.
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      await prefs.setEnabled(value);
    } catch (_) {
      // 기기 저장을 못 써도 이번 실행에는 따른다
    }
    if (value) {
      try {
        await prefs.setAsked();
        if (!await notifier.notificationsAllowed()) _denied = !await notifier.requestPermission();
      } catch (_) {
        // 권한 창을 못 띄움
      }
    }
    _notify();
    await _schedule();
  }

  Future<void> _schedule() => _chain = _chain.then((_) => _apply()).catchError((Object _) {});

  Future<void> _apply() async {
    if (!_enabled) {
      if (_lastSignature != 'off') await notifier.replaceAll(const []);
      _lastSignature = 'off';
      return;
    }
    final allowed = await notifier.notificationsAllowed();
    if (_denied == allowed) {
      _denied = !allowed;
      _notify();
    }
    if (!allowed) {
      if (_lastSignature != 'denied') await notifier.replaceAll(const []);
      _lastSignature = 'denied';
      return;
    }
    if (!_savedKnown) return;
    final cases = _cases;
    await cases?.load();
    final now = _clock();
    final inputs = <ReminderInput>[];
    if (cases != null) {
      for (final e in _saved) {
        final kase = cases[e.notice.noticeId];
        if (kase == null || isEnded(effectiveState(kase, e.notice, now))) continue;
        inputs.add(
          ReminderInput(
            notice: e.notice,
            applicationStart: kase.applicationStart,
            todoLeft: cases.todoRemaining(e.notice.noticeId),
          ),
        );
      }
    }
    final plan = planReminders(inputs, now);
    final signature = plan.map((p) => '${p.at.toIso8601String()}|${p.title}|${p.body}|${p.payload}').join('\n');
    if (signature == _lastSignature) return;
    await notifier.replaceAll(plan);
    _lastSignature = signature;
  }
}

/// 화면이 알림 예약기를 찾는 곳(내 정보 켬·끔 줄, 알림 누름 처리). 없으면(샘플·시험) 알림 기능이 없다.
class ReminderScope extends InheritedNotifier<ReminderService> {
  const ReminderScope({super.key, required ReminderService super.notifier, required super.child});

  static ReminderService? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ReminderScope>()?.notifier;

  static ReminderService? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ReminderScope>()?.notifier;
}
