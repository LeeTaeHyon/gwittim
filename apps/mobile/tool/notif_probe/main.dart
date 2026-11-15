// 알림 기록용 측정 앱 (D-034 1주차). 귀띔 앱과 다른 패키지(kr.gwittim.gwittim.probe)로 설치된다.
//
// 빌드·설치 (apps/mobile, 폰 연결):
//   GWITTIM_PROBE=1 flutter build apk --release -t tool/notif_probe/main.dart
//   adb install -r --user 0 build/app/outputs/flutter-apk/app-release.apk
// 기록 받기 (저장소 루트):
//   adb pull /sdcard/Android/data/kr.gwittim.gwittim.probe/files/notif_probe data/local/
//   uv run python tools/compare_notif_probe.py
//
// 알림 받기와 기록은 Kotlin(android/app/src/probe/)이 하고, 분류는 화면 없는 엔진에서
// 아래 notifProbeBackground가 한다. 이 화면은 권한 상태와 기록 건수만 보여 준다.
//
// 수집기로 빌드 (D-036): 위 빌드 명령에 아래 두 값을 더한다. 토큰은 저장소에 넣지 않는다.
//   --dart-define=GWITTIM_INGEST_URL=https://<API 주소>/v1/ingest/kakao --dart-define=GWITTIM_INGEST_TOKEN=<수집 토큰>
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gwittim/classifier/classifier_assets.dart';

import 'collector.dart';
import 'probe_classify.dart';

const _background = MethodChannel('gwittim/notif_probe');
const _ui = MethodChannel('gwittim/notif_probe_ui');

@pragma('vm:entry-point')
Future<void> notifProbeBackground() async {
  WidgetsFlutterBinding.ensureInitialized();
  final classifier = await loadKakaoClassifier();
  final config = CollectorConfig.fromEnvironment();
  Uploader? uploader;
  Uploader uploaderAt(String dir) => uploader ??= Uploader(Directory(dir), config);
  _background.setMethodCallHandler((call) async {
    final args = (call.arguments as Map).cast<String, Object?>();
    switch (call.method) {
      case 'classify':
        // 측정용: 알림 본문 그대로 분류 (PC 비교 도구가 내보내기 본문 판정과 맞춰 본다)
        final out = classifyForProbe(classifier, args['body'] as String);
        final p = prepare(
          classifier,
          room: args['room'] as String,
          postTimeMillis: args['post_time'] as int,
          body: args['body'] as String,
          history: (args['history'] as List).cast<String>(),
        );
        out['kind'] = p['kind'];
        out['sent_at'] = p['sent_at'];
        out['collector'] = p['classification'];
        if (p['kind'] != 'broadcast') {
          out['upload'] = 'not_broadcast'; // 개인 알림·잡음은 올리지 않는다
        } else if (!config.enabled) {
          out['upload'] = 'disabled';
        } else {
          final u = uploaderAt(args['dir'] as String);
          await u.enqueue(uploadBody(p));
          final r = await u.flush();
          out['upload'] = {'sent': r.sent, 'left': r.left};
        }
        return out;
      case 'flush':
        final r = await uploaderAt(args['dir'] as String).flush();
        return {'sent': r.sent, 'left': r.left};
      default:
        throw MissingPluginException();
    }
  });
  await _background.invokeMethod('ready');
}

void main() => runApp(const MaterialApp(home: ProbeScreen()));

class ProbeScreen extends StatefulWidget {
  const ProbeScreen({super.key});

  @override
  State<ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends State<ProbeScreen> with WidgetsBindingObserver {
  Map<String, Object?>? _status;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh(); // 설정에서 돌아왔을 때
  }

  Future<void> _refresh() async {
    final s = await _ui.invokeMapMethod<String, Object?>('status');
    if (mounted) setState(() => _status = s);
  }

  String _last() {
    final line = _status?['last_record'] as String?;
    if (line == null) return '없음';
    final r = jsonDecode(line) as Map<String, dynamic>;
    return '${r['received_at']} · ${r['room']}';
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final on = s?['permission'] == true;
    return Scaffold(
      appBar: AppBar(title: const Text('귀띔 측정')),
      body: s == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  on ? '알림 읽기 권한: 켜짐' : '알림 읽기 권한: 꺼짐',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                const Text('카카오톡 명지전문대학 채널 6곳의 알림만 기록합니다. 다른 알림은 저장하지 않습니다.'),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => _ui.invokeMethod('openSettings'),
                  child: const Text('알림 읽기 권한 설정 열기'),
                ),
                const Divider(height: 32),
                Text('기록한 알림: ${s['records']}건'),
                Text('기기 안 분류: ${s['classified']}건'),
                Text(CollectorConfig.fromEnvironment().enabled
                    ? '서버로 올림: ${s['uploaded']}건 · 대기 ${s['pending']}건'
                    : '서버로 올리기: 꺼짐 (기록만)'),
                Text('마지막 기록: ${_last()}'),
                if (s['last_event'] != null) Text('마지막 상태: ${s['last_event']}'),
                const SizedBox(height: 12),
                SelectableText('저장 위치: ${s['dir']}', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
    );
  }
}
