// 기기 안 계산(lib/classifier)과 서버 분류기의 판정을 알림톡 전부로 비교한다. 파일은 쓰지 않는다.
//
// 먼저 저장소 루트에서 서버 기준값을 만든다:  uv run python tools/dump_classifier_probs.py
// 그다음 apps/mobile에서:                      dart run tool/classifier_parity.dart
//
// 인자(선택): [notices.jsonl 경로] [서버 기준값 경로]
// 출력: 관심사·종류·애매함 판정 일치 수, 최대 확률 차, 이 PC에서 한 건 분류 시간(참고치. 폰 값이 아님).
import 'dart:convert';
import 'dart:io';

import 'package:gwittim/classifier/kakao_classifier.dart';
import 'package:gwittim/classifier/text_model.dart';

const _models = '../../backend/classifier/models';

double _percentile(List<int> sorted, double q) => sorted[((sorted.length - 1) * q).round()] / 1000;

void main(List<String> args) {
  final noticesPath = args.isNotEmpty
      ? args[0]
      : '../../localModel/kakaoTalk_data/processed/notices.jsonl';
  final serverPath = args.length > 1 ? args[1] : '../../data/local/classifier_server_probs.jsonl';

  TextModel load(String name) => TextModel.fromBytes(
    File('$_models/$name.json').readAsStringSync(),
    File('$_models/$name.bin').readAsBytesSync(),
  );
  final classifier = KakaoClassifier(load(interestModelName), load(categoryModelName));

  List<Map<String, dynamic>> lines(String path) => [
    for (final l in File(path).readAsLinesSync())
      if (l.trim().isNotEmpty) jsonDecode(l) as Map<String, dynamic>,
  ];
  final notices = lines(noticesPath);
  final server = {for (final r in lines(serverPath)) r['id'] as String: r};

  var interestSame = 0, categorySame = 0, unsureSame = 0, missing = 0;
  var maxInterestDiff = 0.0, maxCategoryDiff = 0.0;
  final different = <String>[];
  for (final n in notices) {
    final s = server[n['id']];
    if (s == null) {
      missing++;
      continue;
    }
    final title = n['title'] as String, body = n['text'] as String;
    final r = classifier.classify(title, body);
    final ip = classifier.interest.probs(textOf(title, body));
    final sip = (s['interest_probs'] as List).cast<num>();
    final scp = (s['category_probs'] as List).cast<num>();
    for (var i = 0; i < sip.length; i++) {
      final d = (ip[i] - sip[i]).abs();
      if (d > maxInterestDiff) maxInterestDiff = d;
    }
    for (var i = 0; i < scp.length; i++) {
      final d = (r.categoryProbs[i] - scp[i]).abs();
      if (d > maxCategoryDiff) maxCategoryDiff = d;
    }
    final sameInterest = r.interestIds.join(' ') == (s['interest_ids'] as List).join(' ');
    final sameCategory = r.category == s['category'];
    final sameUnsure = r.unsure == s['unsure'];
    if (sameInterest) interestSame++;
    if (sameCategory) categorySame++;
    if (sameUnsure) unsureSame++;
    if (!(sameInterest && sameCategory && sameUnsure)) different.add(n['id'] as String);
  }

  // 시간: 준비 운동 한 바퀴 뒤 5바퀴. 공지 한 건(두 모델)의 마이크로초.
  for (final n in notices) {
    classifier.classify(n['title'] as String, n['text'] as String);
  }
  final micros = <int>[];
  final watch = Stopwatch();
  for (var round = 0; round < 5; round++) {
    for (final n in notices) {
      watch
        ..reset()
        ..start();
      classifier.classify(n['title'] as String, n['text'] as String);
      watch.stop();
      micros.add(watch.elapsedMicroseconds);
    }
  }
  micros.sort();

  final total = notices.length - missing;
  stdout.writeln('비교 $total건 (서버 기준값 없음 $missing건)');
  stdout.writeln('관심사 판정 일치 $interestSame/$total, 최대 확률 차 ${maxInterestDiff.toStringAsExponential(2)}');
  stdout.writeln('종류 판정 일치 $categorySame/$total, 최대 확률 차 ${maxCategoryDiff.toStringAsExponential(2)}');
  stdout.writeln('애매함 판정 일치 $unsureSame/$total');
  if (different.isNotEmpty) stdout.writeln('다른 공지: ${different.join(' ')}');
  stdout.writeln(
    '이 PC에서 한 건 분류 시간(참고치): p50 ${_percentile(micros, 0.5).toStringAsFixed(3)}ms, '
    'p95 ${_percentile(micros, 0.95).toStringAsFixed(3)}ms',
  );
  exitCode = different.isEmpty && missing == 0 ? 0 : 1;
}
