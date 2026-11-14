// 기기 안 분류 계산이 서버(backend/classifier)와 같은 값을 내는지 검사한다 (D-034).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/classifier/classifier_assets.dart';
import 'package:gwittim/classifier/kakao_classifier.dart';
import 'package:gwittim/classifier/text_model.dart';

// 서버가 쓰는 원본. 파이썬 테스트(test_classifier.py)도 같은 파일의 check 값을 읽는다.
const _serverDir = '../../backend/classifier/models';
const _assetDir = 'assets/classifier';
const _models = [interestModelName, categoryModelName];

TextModel _load(String name) => TextModel.fromBytes(
  File('$_serverDir/$name.json').readAsStringSync(),
  File('$_serverDir/$name.bin').readAsBytesSync(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final name in _models) {
    test('$name: Keras로 계산한 확률과 같다', () {
      final meta = jsonDecode(File('$_serverDir/$name.json').readAsStringSync()) as Map;
      final cases = (meta['check'] as List).cast<Map>();
      expect(cases.length, greaterThanOrEqualTo(50));
      final model = _load(name);
      for (final c in cases) {
        final expected = (c['probs'] as List).cast<num>();
        final actual = model.probs(c['text'] as String);
        expect(actual.length, expected.length);
        for (var i = 0; i < expected.length; i++) {
          expect(actual[i], closeTo(expected[i], 1e-5), reason: '${c['text']} [$i]');
        }
      }
    });

    test('$name: 앱에 넣은 사본이 서버 원본과 같다', () {
      for (final ext in ['json', 'bin']) {
        expect(
          File('$_assetDir/$name.$ext').readAsBytesSync(),
          File('$_serverDir/$name.$ext').readAsBytesSync(),
          reason: 'backend/classifier/models/$name.$ext 를 assets/classifier/로 다시 복사',
        );
      }
    });
  }

  test('글자 나누기가 Keras standardize와 같다', () {
    final model = _load(categoryModelName);
    // ASCII만 소문자로 바꾸고 문장부호는 지운 뒤 글자 하나씩
    expect(model.tokens('AI, 특강!'), model.tokens('ai 특강'));
    // 전각 영문은 소문자로 바꾸지 않는다 (단어장에 없어 모르는 토큰 1이 된다)
    expect(model.tokens('ai'), everyElement(greaterThan(1)));
    expect(model.tokens('ＡＩ'), [1, 1]);
    // 학습 때 길이까지만 본다
    expect(model.tokens('가' * 1000).length, model.seqLen);
    // 이모지처럼 UTF-16 두 단위인 글자도 한 글자로 센다
    expect(model.tokens('📢').length, 1);
    expect(model.tokens('📢' * 1000).length, model.seqLen);
    expect(model.tokens(''), isEmpty);
    expect(model.tokens('!?.,'), isEmpty);
  });

  test('링크는 빼고 제목과 본문을 잇는다', () {
    expect(textOf('제목', '신청 https://example.com/a?b=1 까지'), '제목\n신청   까지');
    expect(textOf('제목', 'http://example.com'), '제목\n ');
    // 전각 공백(U+3000)에서 링크가 끝난다 (파이썬 \S와 같음)
    expect(textOf('', 'https://a.b　뒤'), '\n 　뒤');
  });

  test('가중치 크기가 설정과 다르면 오류', () {
    final meta = File('$_serverDir/$interestModelName.json').readAsStringSync();
    expect(() => TextModel.fromBytes(meta, Uint8List(8)), throwsFormatException);
  });

  test('분류 결과: 문턱 이상 꼬리표, 가장 높은 종류, 애매함 표시', () {
    final classifier = KakaoClassifier(_load(interestModelName), _load(categoryModelName));
    final r = classifier.classify('글로벌교육센터 겨울방학 영어 회화 어학 프로그램 안내', 'TOEIC 대비반 포함');
    expect(r.interestIds, ['global_language']);
    expect(r.category, 'education_program');

    final threshold = classifier.interest.threshold!, other = classifier.interest.otherThreshold!;
    for (final text in ['', '2026 교내 AI 데이터 분석 경진대회 참가팀 모집', '도서관 독서 감상문 공모전 안내']) {
      final c = classifier.classify(text, '');
      expect(c.interestIds, [
        for (final e in c.interestProbs.entries)
          if (e.value >= threshold) e.key,
      ]);
      final near = c.interestProbs.values.any((p) => (p - threshold).abs() < band);
      expect(c.unsure, c.otherProb >= other || near);
      expect(c.categoryProbs.reduce((a, b) => a + b), closeTo(1, 1e-9));
    }
  });

  testWidgets('앱 자산에서 분류기를 읽는다', (tester) async {
    final classifier = await tester.runAsync(loadKakaoClassifier);
    expect(classifier!.interest.classes, ['ai_data', 'global_language', 'media_content']);
    expect(classifier.category.classes.length, 12);
  });
}
