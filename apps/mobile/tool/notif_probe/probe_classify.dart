// 알림 본문 한 건을 기기 안 분류기로 분류해 기록할 값을 만든다 (D-034 1주차 측정).
import 'package:gwittim/classifier/kakao_classifier.dart';

/// 알림 본문의 제목: 빈 줄을 건너뛴 첫 줄 (80자까지).
/// 내보내기 파서의 제목 규칙(인사·부서 소개 줄 건너뛰기)보다 단순하다. PC 비교 도구가 파서 규칙으로 다시 분류한다.
String probeTitle(String body) {
  for (final line in body.split('\n')) {
    final s = line.trim();
    if (s.isEmpty) continue;
    final runes = s.runes.toList();
    return runes.length <= 80 ? s : String.fromCharCodes(runes.take(80));
  }
  return '';
}

Map<String, Object?> classifyForProbe(KakaoClassifier classifier, String body) {
  final title = probeTitle(body);
  final watch = Stopwatch()..start();
  final r = classifier.classify(title, body);
  watch.stop();
  return {
    'title': title,
    'interest_ids': r.interestIds,
    'category': r.category,
    'unsure': r.unsure,
    'interest_probs': r.interestProbs,
    'other_prob': r.otherProb,
    'micros': watch.elapsedMicroseconds,
  };
}
