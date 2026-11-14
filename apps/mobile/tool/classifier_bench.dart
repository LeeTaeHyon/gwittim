// 폰에서 알림톡 한 건을 분류하는 데 걸리는 시간을 잰다 (D-034 1주차 측정).
//
// 실행 (apps/mobile, 폰 연결):  flutter run --profile -t tool/classifier_bench.dart
// 결과는 화면과 로그(CLASSIFIER_BENCH 로 시작하는 줄)에 나온다.
//
// - 같은 패키지 이름으로 설치되므로 폰의 귀띔 앱이 이 측정 화면으로 바뀐다. 잰 뒤 배포용 APK를 다시 설치한다.
// - 실제 알림톡은 앱에 넣지 않는다. 모델 파일의 합성 문장(check)을 이어 붙여 길이별 글을 만든다.
//   시간은 글자 수(최대 600자)에만 달려 있다. 354자는 알림톡 287건 본문의 중앙값이다.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gwittim/classifier/classifier_assets.dart';
import 'package:gwittim/classifier/kakao_classifier.dart';

const _lengths = [100, 354, 600];
const _rounds = 2000;

Future<List<String>> _measure() async {
  final classifier = await loadKakaoClassifier();
  final meta =
      jsonDecode(await rootBundle.loadString('assets/classifier/$interestModelName.json')) as Map;
  final seed = [for (final c in meta['check'] as List) (c as Map)['text'] as String].join('\n');
  final lines = <String>[];
  for (final length in _lengths) {
    final runes = seed.runes.toList();
    final text = String.fromCharCodes([for (var i = 0; i < length; i++) runes[i % runes.length]]);
    for (var i = 0; i < 200; i++) {
      classifier.classify('', text); // 준비 운동
    }
    final micros = <int>[];
    final watch = Stopwatch();
    for (var i = 0; i < _rounds; i++) {
      watch
        ..reset()
        ..start();
      classifier.classify('', text);
      watch.stop();
      micros.add(watch.elapsedMicroseconds);
    }
    micros.sort();
    String ms(double q) => (micros[((micros.length - 1) * q).round()] / 1000).toStringAsFixed(3);
    lines.add('$length자: p50 ${ms(0.5)}ms, p95 ${ms(0.95)}ms, 최대 ${ms(1)}ms ($_rounds회)');
  }
  return lines;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const mode = kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug');
  runApp(
    MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: FutureBuilder<List<String>>(
            future: _measure(),
            builder: (context, snapshot) {
              final lines = snapshot.data;
              if (lines == null) {
                return Center(child: Text(snapshot.hasError ? '측정 실패' : '측정 중'));
              }
              for (final l in lines) {
                debugPrint('CLASSIFIER_BENCH $mode $l');
              }
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Text('알림톡 한 건 분류 시간 ($mode)\n\n${lines.join('\n')}'),
              );
            },
          ),
        ),
      ),
    ),
  );
}
