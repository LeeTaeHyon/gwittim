// 알림 기록용 측정 앱의 기기 안 분류 (D-034).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/classifier/kakao_classifier.dart';
import 'package:gwittim/classifier/text_model.dart';

import '../tool/notif_probe/probe_classify.dart';

const _models = '../../backend/classifier/models';

TextModel _load(String name) => TextModel.fromBytes(
  File('$_models/$name.json').readAsStringSync(),
  File('$_models/$name.bin').readAsBytesSync(),
);

void main() {
  test('제목은 빈 줄을 건너뛴 첫 줄, 80자까지', () {
    expect(probeTitle('\n\n  글로벌 어학 아카데미 안내  \n본문'), '글로벌 어학 아카데미 안내');
    expect(probeTitle(''), '');
    expect(probeTitle('📢' * 100).runes.length, 80);
  });

  test('분류 결과는 같은 제목·본문으로 분류기를 부른 값과 같다', () {
    final classifier = KakaoClassifier(_load(interestModelName), _load(categoryModelName));
    const body = '글로벌교육센터 겨울방학 영어 회화 어학 프로그램 안내\nTOEIC 대비반 포함';
    final r = classifyForProbe(classifier, body);
    final direct = classifier.classify('글로벌교육센터 겨울방학 영어 회화 어학 프로그램 안내', body);
    expect(r['title'], '글로벌교육센터 겨울방학 영어 회화 어학 프로그램 안내');
    expect(r['interest_ids'], direct.interestIds);
    expect(r['category'], direct.category);
    expect(r['unsure'], direct.unsure);
    expect(r['other_prob'], direct.otherProb);
    expect(r['micros'], isA<int>());
  });
}
