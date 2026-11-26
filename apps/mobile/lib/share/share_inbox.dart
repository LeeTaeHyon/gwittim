import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 다른 앱(카카오톡·갤러리)에서 귀띔으로 넘어온 것 (MainActivity.kt의 ACTION_SEND 처리, D-058).
sealed class SharedPayload {
  const SharedPayload();
}

class SharedText extends SharedPayload {
  const SharedText(this.text);

  final String text;
}

/// 캡처 이미지. [path]는 앱 캐시에 복사한 파일이다. 글자 인식이 끝나면 지운다(서버로 보내지 않음).
class SharedImage extends SharedPayload {
  const SharedImage(this.path);

  final String path;
}

/// 받은 공유를 로그인·화면이 준비될 때까지 들고 있는다.
/// 콜드 스타트는 시작할 때 [start]가 한 번 가져오고, 앱이 켜져 있을 때는 네이티브가 arrived로 알려 다시 가져온다.
class ShareInbox extends ChangeNotifier {
  ShareInbox({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('kr.gwittim.gwittim/share');

  final MethodChannel _channel;
  SharedPayload? _pending;

  SharedPayload? get pending => _pending;

  Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'arrived') await _take();
    });
    await _take();
  }

  Future<void> _take() async {
    try {
      final map = await _channel.invokeMapMethod<String, String>('take');
      if (map != null) offer(parseShare(map));
    } on PlatformException {
      // 받지 못하면 그냥 넘어간다. 사용자는 붙여넣기로도 넘길 수 있다.
    } on MissingPluginException {
      // 테스트·다른 플랫폼
    }
  }

  /// 화면이 가져간다. 한 번만 처리하도록 비운다.
  SharedPayload? consume() {
    final p = _pending;
    _pending = null;
    return p;
  }

  void offer(SharedPayload? payload) {
    if (payload == null) return;
    _pending = payload;
    notifyListeners();
  }
}

/// 네이티브가 준 값 → [SharedPayload]. 모르는 값은 null.
SharedPayload? parseShare(Map<String, String> map) {
  switch (map['kind']) {
    case 'text':
      final text = map['text'];
      return text == null || text.trim().isEmpty ? null : SharedText(text);
    case 'image':
      final path = map['path'];
      return path == null || path.isEmpty ? null : SharedImage(path);
  }
  return null;
}

/// 공유 이미지 임시 파일 지우기. 없어도 오류 없이 넘어간다.
Future<void> deleteShareFile(String path) async {
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
  } catch (_) {
    // 캐시 폴더라 남아도 시스템이 정리한다
  }
}

/// 카카오톡 공고 넘기기 동의 기록. 기기에 문구 버전을 남기고, 서버는 요청마다 같은 버전을 확인한다(D-058).
abstract class ShareConsentStore {
  Future<String?> readVersion();
  Future<void> writeVersion(String version);
  Future<void> clear();
}

class PrefsShareConsentStore implements ShareConsentStore {
  static const key = 'share_consent_version';

  @override
  Future<String?> readVersion() async =>
      (await SharedPreferences.getInstance()).getString(key);

  @override
  Future<void> writeVersion(String version) async =>
      (await SharedPreferences.getInstance()).setString(key, version);

  @override
  Future<void> clear() async =>
      (await SharedPreferences.getInstance()).remove(key);
}

class MemoryShareConsentStore implements ShareConsentStore {
  MemoryShareConsentStore([this._version]);

  String? _version;

  @override
  Future<String?> readVersion() async => _version;

  @override
  Future<void> writeVersion(String version) async => _version = version;

  @override
  Future<void> clear() async => _version = null;
}
