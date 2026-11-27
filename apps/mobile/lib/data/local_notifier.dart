import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'reminders.dart';

/// 기기 알림 예약기: flutter_local_notifications로 이 기기 안에서 예약한다(서버 푸시 아님, D-061).
///
/// - 정확한 알람 권한을 쓰지 않는다(`inexactAllowWhileIdle`): 몇 분 늦을 수 있다.
/// - 재부팅 뒤 예약 복구는 플러그인의 부팅 수신기가 한다(AndroidManifest).
/// - 알림 표시 권한(Android 13+)은 [requestPermission]이 묻는다. 앱 시작 때는 묻지 않는다.
class LocalNotifier implements ReminderNotifier {
  LocalNotifier({FlutterLocalNotificationsPlugin? plugin}) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final _taps = StreamController<String>.broadcast();
  bool _ready = false;
  Future<void>? _initializing;

  static const _channelId = 'deadline_reminder';

  /// 한 번만 준비한다. 앱을 시작할 때 부른다(권한은 묻지 않음).
  Future<void> init() => _initializing ??= _init();

  Future<void> _init() async {
    tzdata.initializeTimeZones();
    tz.setLocalLocation(_deviceLocation());
    await _plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: (response) => _taps.add(response.payload ?? ''),
    );
    _ready = true;
  }

  /// 기기 시간대와 UTC 오프셋이 같은 지역. 한국 기기는 Asia/Seoul. 알림 시각은 오프셋만 맞으면 정확하다.
  static tz.Location _deviceLocation() {
    final offset = DateTime.now().timeZoneOffset;
    final seoul = tz.getLocation('Asia/Seoul');
    if (tz.TZDateTime.now(seoul).timeZoneOffset == offset) return seoul;
    for (final location in tz.timeZoneDatabase.locations.values) {
      if (tz.TZDateTime.now(location).timeZoneOffset == offset) return location;
    }
    return tz.UTC;
  }

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  @override
  Stream<String> get taps => _taps.stream;

  @override
  Future<String?> launchPayload() async {
    await init();
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    return details.notificationResponse?.payload ?? '';
  }

  @override
  Future<bool> notificationsAllowed() async {
    await init();
    final android = _android;
    if (android == null) return true; // 권한을 물을 수 없는 플랫폼
    return await android.areNotificationsEnabled() ?? false;
  }

  @override
  Future<bool> requestPermission() async {
    await init();
    final android = _android;
    if (android == null) return true;
    return await android.requestNotificationsPermission() ?? false;
  }

  @override
  Future<void> replaceAll(List<PlannedReminder> plan) async {
    await init();
    if (!_ready) return;
    await _plugin.cancelAll();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        '마감 알림',
        channelDescription: '저장한 공고의 신청 시작·마감 전에 알립니다.',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
    );
    for (final (i, p) in plan.indexed) {
      await _plugin.zonedSchedule(
        id: i + 1,
        title: p.title,
        body: p.body,
        scheduledDate: tz.TZDateTime.from(p.at, tz.local),
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: p.payload,
      );
    }
  }
}
