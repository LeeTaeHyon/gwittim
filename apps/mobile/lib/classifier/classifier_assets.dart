// 앱에 넣은 모델 파일(assets/classifier/)로 분류기를 만든다.
import 'package:flutter/services.dart';

import 'kakao_classifier.dart';

const String _dir = 'assets/classifier';

Future<KakaoClassifier> loadKakaoClassifier([AssetBundle? bundle]) async {
  final assets = bundle ?? rootBundle;
  Future<Uint8List> bin(String name) async =>
      (await assets.load('$_dir/$name.bin')).buffer.asUint8List();
  return KakaoClassifier.fromBytes(
    interestMeta: await assets.loadString('$_dir/$interestModelName.json'),
    interestWeights: await bin(interestModelName),
    categoryMeta: await assets.loadString('$_dir/$categoryModelName.json'),
    categoryWeights: await bin(categoryModelName),
  );
}
