// 알림톡 한 건을 기기 안에서 분류한다 (D-034).
//
// backend/classifier/cascade.py의 classify에서 Gemma 호출을 뺀 것과 같다.
// 기기에는 Gemma가 없으므로 애매한 공지는 [Classification.unsure]로만 알린다.
// 애매함은 '기타' 확률이 기타 문턱 이상일 때 하나다(배운 꼬리표 밖의 분야일 수 있음, D-035).
import 'dart:typed_data';

import 'text_model.dart';

// 둘 다 사람 정답으로 학습한 모델 (D-035)
const String interestModelName = 'interest_char_avg_human';
const String categoryModelName = 'category_char_avg_board_human';

class Classification {
  const Classification({
    required this.interestIds,
    required this.category,
    required this.unsure,
    required this.interestProbs,
    required this.otherProb,
    required this.categoryProbs,
  });

  final List<String> interestIds;
  final String category;

  /// 서버라면 관심사를 Gemma에 넘겼을 공지인지 (기타 확률이 기타 문턱 이상)
  final bool unsure;
  final Map<String, double> interestProbs;
  final double otherProb;
  final List<double> categoryProbs;
}

class KakaoClassifier {
  KakaoClassifier(this.interest, this.category);

  factory KakaoClassifier.fromBytes({
    required String interestMeta,
    required Uint8List interestWeights,
    required String categoryMeta,
    required Uint8List categoryWeights,
  }) => KakaoClassifier(
    TextModel.fromBytes(interestMeta, interestWeights),
    TextModel.fromBytes(categoryMeta, categoryWeights),
  );

  final TextModel interest;
  final TextModel category;

  Classification classify(String title, String body) {
    final doc = textOf(title, body);
    final ip = interest.probs(doc), cp = category.probs(doc);
    final n = interest.classes.length;
    final threshold = interest.threshold!, otherThreshold = interest.otherThreshold!;
    final otherProb = ip[n]; // 마지막 칸은 '기타'

    final unsure = otherProb >= otherThreshold;
    final ids = <String>[];
    final tagProbs = <String, double>{};
    for (var i = 0; i < n; i++) {
      final p = ip[i];
      tagProbs[interest.classes[i]] = p;
      if (p >= threshold) ids.add(interest.classes[i]);
    }
    var best = 0;
    for (var k = 1; k < cp.length; k++) {
      if (cp[k] > cp[best]) best = k; // 같은 값이면 앞의 것 (파이썬 index(max)와 같음)
    }
    return Classification(
      interestIds: ids,
      category: category.classes[best],
      unsure: unsure,
      interestProbs: tagProbs,
      otherProb: otherProb,
      categoryProbs: cp,
    );
  }
}
