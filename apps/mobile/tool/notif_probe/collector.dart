// 팀장 폰 수집기 (D-034, D-036): 학교 채널 알림 본문 → 개인 알림 거르기·가림 → 분류 → 공통 공지면 서버로 올린다.
//
// 서버(/v1/ingest/kakao)는 받은 글을 받은편지함에 두고, PC 배치가 카톡 내보내기와 함께 분석·게시한다.
// 수집 주소와 토큰은 빌드할 때만 넣는다(--dart-define). 넣지 않으면 올리지 않고 기록만 한다(측정 앱).
//   --dart-define=GWITTIM_INGEST_URL=https://<API 주소>/v1/ingest/kakao
//   --dart-define=GWITTIM_INGEST_TOKEN=<수집 토큰>   (저장소에 넣지 않는다)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gwittim/classifier/kakao_classifier.dart';
import 'package:gwittim/classifier/kakao_filter.dart';

const String queueFile = 'upload_queue.jsonl'; // 아직 못 올린 공통 공지 (가린 본문)
const String uploadedFile = 'uploaded.jsonl'; // 올린 기록 (본문 없음)

class CollectorConfig {
  const CollectorConfig(this.endpoint, this.token);

  factory CollectorConfig.fromEnvironment() {
    const url = String.fromEnvironment('GWITTIM_INGEST_URL');
    const token = String.fromEnvironment('GWITTIM_INGEST_TOKEN');
    return CollectorConfig(url.isEmpty ? null : Uri.parse(url), token.isEmpty ? null : token);
  }

  final Uri? endpoint;
  final String? token;

  bool get enabled => endpoint != null && token != null;
}

/// 알림을 받은 시각(밀리초) → 내보내기와 같은 분 단위 한국 시각 '2026-10-20T14:05:00+09:00'.
String kstMinute(int postTimeMillis) {
  final t = DateTime.fromMillisecondsSinceEpoch(postTimeMillis, isUtc: true).add(const Duration(hours: 9));
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}T${two(t.hour)}:${two(t.minute)}:00+09:00';
}

/// 알림 한 건을 거르고 가리고 분류한다. [history]는 이전에 받은 학교 채널 알림 본문(받는 사람 이름 찾기용).
///
/// 돌려주는 값에 가린 본문(text)이 있다. 공통 공지(kind == 'broadcast')만 올린다.
Map<String, Object?> prepare(
  KakaoClassifier classifier, {
  required String room,
  required int postTimeMillis,
  required String body,
  List<String> history = const [],
}) {
  final cleaned = cleanBody(body);
  final names = detectNames([...history.map(cleanBody), cleaned]);
  final kind = kakaoKind(cleaned, names);
  final masked = maskPersonal(cleaned, names);
  final title = kakaoTitle(masked, room);
  // 서버 배치와 같은 입력: 제목(없으면 방 이름) + 가린 본문
  final r = classifier.classify(title.isEmpty ? room : title, masked);
  return {
    'kind': kind,
    'room': room,
    'sent_at': kstMinute(postTimeMillis),
    'title': title,
    'text': masked,
    'model_version': modelVersion,
    'classification': {'category': r.category, 'interest_ids': r.interestIds, 'unsure': r.unsure},
  };
}

/// 올릴 값: 가린 본문과 폰의 분류 결과. 원문·받는 사람 이름은 보내지 않는다.
Map<String, Object?> uploadBody(Map<String, Object?> prepared) => {
  for (final k in ['room', 'sent_at', 'text', 'model_version', 'classification']) k: prepared[k],
  'app_version': 'notif-probe',
};

typedef Post = Future<int> Function(Uri endpoint, String token, String json);

/// dart:io로 올린다. 응답 코드(연결 실패는 0).
Future<int> httpPost(Uri endpoint, String token, String json) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.postUrl(endpoint);
    req.headers.contentType = ContentType.json;
    req.headers.set('X-Ingest-Token', token);
    req.add(utf8.encode(json));
    final res = await req.close().timeout(const Duration(seconds: 20));
    await res.drain<void>();
    return res.statusCode;
  } on Object {
    return 0;
  } finally {
    client.close(force: true);
  }
}

/// 대기열에 넣고 쌓인 것을 순서대로 올린다. 한 번에 하나씩만 돈다.
class Uploader {
  Uploader(this.dir, this.config, {Post? post}) : _post = post ?? httpPost;

  final Directory dir;
  final CollectorConfig config;
  final Post _post;
  Future<void> _running = Future.value();

  File get _queue => File('${dir.path}/$queueFile');
  File get _uploaded => File('${dir.path}/$uploadedFile');

  Future<void> enqueue(Map<String, Object?> body) =>
      _serial(() async => _queue.writeAsString('${jsonEncode(body)}\n', mode: FileMode.append, flush: true));

  /// 쌓인 것을 올린다. 400(형식 오류)은 다시 올려도 안 되므로 버리고, 나머지 실패는 다음에 다시 올린다.
  Future<({int sent, int left})> flush() async {
    var result = (sent: 0, left: 0);
    await _serial(() async {
      if (!config.enabled || !await _queue.exists()) {
        result = (sent: 0, left: await _count(_queue));
        return;
      }
      final lines = (await _queue.readAsLines()).where((l) => l.trim().isNotEmpty).toList();
      final keep = <String>[];
      var sent = 0;
      for (final line in lines) {
        final code = keep.isEmpty ? await _post(config.endpoint!, config.token!, line) : -1; // 한 번 실패하면 이번엔 멈춘다
        if (code == 200 || code == 400) {
          final b = jsonDecode(line) as Map<String, dynamic>;
          await _uploaded.writeAsString(
            '${jsonEncode({'at': DateTime.now().toUtc().toIso8601String(), 'room': b['room'], 'sent_at': b['sent_at'], 'status': code})}\n',
            mode: FileMode.append,
            flush: true,
          );
          if (code == 200) sent++;
        } else {
          keep.add(line);
        }
      }
      await _queue.writeAsString(keep.map((l) => '$l\n').join(), flush: true);
      result = (sent: sent, left: keep.length);
    });
    return result;
  }

  Future<int> _count(File f) async =>
      await f.exists() ? (await f.readAsLines()).where((l) => l.trim().isNotEmpty).length : 0;

  Future<void> _serial(Future<void> Function() task) {
    final next = _running.then((_) => task());
    _running = next.catchError((_) {});
    return next;
  }
}
