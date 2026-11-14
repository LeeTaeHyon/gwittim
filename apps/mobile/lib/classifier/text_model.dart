// 알림톡 분류 모델(임베딩 → 평균 풀링 → Dense)을 기기 안에서 계산한다 (D-034).
//
// backend/classifier/text_model.py와 같은 값을 내야 한다. 가중치·단어장 파일도 같은 것을 쓴다
// (backend/classifier/models/<이름>.json·.bin, 앱에는 assets/classifier/에 사본).
// 같은지는 test/classifier_test.dart가 모델 파일의 check 값(Keras로 계산한 확률)으로 검사한다.
//
// 이 파일은 Flutter를 쓰지 않는다. `dart run`으로 도는 비교 도구(tool/classifier_parity.dart)도 같이 쓴다.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

// 파이썬 re의 \S와 같은 범위. Dart의 \S는 U+FEFF를 공백으로 보고 U+001C~1F·U+0085를 공백으로 보지 않아 다르다.
final RegExp _url = RegExp(
  'https?://[^\\t\\n\\u000b\\u000c\\r\\u001c-\\u001f \\u0085\\u00a0\\u1680\\u2000-\\u200a'
  '\\u2028\\u2029\\u202f\\u205f\\u3000]+',
);

// Keras TextVectorization 'lower_and_strip_punctuation'이 지우는 문자
final Set<int> _punctuation = '!"#\$%&()*+,-./:;<=>?@[\\]^_`{|}~\''.codeUnits.toSet();

// tf.strings.split의 공백은 ASCII 공백뿐 (공백, \t, \n, \v, \f, \r)
bool _isAsciiSpace(int c) => c == 0x20 || (c >= 0x09 && c <= 0x0d);

/// 학습 때 모델에 넣은 글과 같은 모양. 링크는 뺀다.
String textOf(String title, String body) => '$title\n$body'.replaceAll(_url, ' ');

class TextModel {
  TextModel._({
    required this.name,
    required this.unit,
    required this.seqLen,
    required this.classes,
    required this.threshold,
    required this.otherThreshold,
    required this.activation,
    required this.dim,
    required this.outputs,
    required this._index,
    required this._embedding,
    required this._kernel,
    required this._bias,
  });

  final String name;
  final String unit; // "char" 또는 "word"
  final int seqLen;
  final List<String> classes;
  final double? threshold;
  final double? otherThreshold;
  final String activation; // "sigmoid" 또는 "softmax"
  final int dim;
  final int outputs;
  final Map<String, int> _index;
  final Float32List _embedding; // 단어장 크기 × dim
  final Float32List _kernel; // dim × outputs (행 우선)
  final Float32List _bias;

  /// [metaJson]은 <이름>.json의 글자, [weights]는 <이름>.bin(리틀 엔디언 float32).
  factory TextModel.fromBytes(String metaJson, Uint8List weights) {
    final meta = jsonDecode(metaJson) as Map<String, dynamic>;
    final name = meta['name'] as String;
    final vocab = (meta['vocab'] as List).cast<String>();
    final embeddingShape = (meta['embedding_shape'] as List).cast<int>();
    final vocabSize = embeddingShape[0], dim = embeddingShape[1];
    final outputs = (meta['dense_shape'] as List).cast<int>()[1];
    final expected = vocabSize * dim + dim * outputs + outputs;
    if (weights.lengthInBytes != expected * 4) {
      throw FormatException('$name: 가중치 크기가 설정과 다름');
    }
    final data = ByteData.sublistView(weights);
    final all = Float32List(expected);
    for (var i = 0; i < expected; i++) {
      all[i] = data.getFloat32(i * 4, Endian.little);
    }
    final index = <String, int>{};
    for (var i = 2; i < vocab.length; i++) {
      index[vocab[i]] = i; // 0 빈칸, 1 모르는 토큰
    }
    final eEnd = vocabSize * dim, kEnd = eEnd + dim * outputs;
    return TextModel._(
      name: name,
      unit: meta['unit'] as String,
      seqLen: meta['seq_len'] as int,
      classes: (meta['classes'] as List).cast<String>(),
      threshold: (meta['threshold'] as num?)?.toDouble(),
      otherThreshold: (meta['other_threshold'] as num?)?.toDouble(),
      activation: meta['activation'] as String,
      dim: dim,
      outputs: outputs,
      index: index,
      embedding: Float32List.sublistView(all, 0, eEnd),
      kernel: Float32List.sublistView(all, eEnd, kEnd),
      bias: Float32List.sublistView(all, kEnd),
    );
  }

  /// 글을 단어장 번호로 바꾼다. 뒤쪽 빈칸(0)은 평균에서 빠지므로 채우지 않는다.
  List<int> tokens(String text) {
    // 파이썬은 코드 포인트로 센다. Dart 문자열은 UTF-16이라 runes로 나눠야 이모지가 한 글자가 된다.
    final cleaned = <int>[];
    for (final rune in text.runes) {
      if (_punctuation.contains(rune)) continue;
      // ASCII만 소문자로 (tf.strings.lower와 같음. 로마 숫자·전각 문자는 그대로)
      cleaned.add(rune >= 0x41 && rune <= 0x5a ? rune + 0x20 : rune);
    }
    final ids = <int>[];
    if (unit == 'char') {
      for (final rune in cleaned) {
        if (ids.length == seqLen) break;
        ids.add(_index[String.fromCharCode(rune)] ?? 1);
      }
      return ids;
    }
    var start = -1;
    for (var i = 0; i <= cleaned.length; i++) {
      final space = i == cleaned.length || _isAsciiSpace(cleaned[i]);
      if (!space) {
        if (start < 0) start = i;
        continue;
      }
      if (start >= 0) {
        if (ids.length == seqLen) break;
        ids.add(_index[String.fromCharCodes(cleaned, start, i)] ?? 1);
        start = -1;
      }
    }
    return ids;
  }

  /// 출력 칸마다의 확률. 계산 순서는 text_model.py의 probs와 같다.
  List<double> probs(String text) {
    final ids = tokens(text);
    final pooled = Float64List(dim);
    for (final t in ids) {
      final row = t * dim;
      for (var d = 0; d < dim; d++) {
        pooled[d] += _embedding[row + d];
      }
    }
    final n = ids.isEmpty ? 1 : ids.length; // 토큰이 하나도 없으면 0 벡터
    final logits = Float64List(outputs);
    for (var k = 0; k < outputs; k++) {
      logits[k] = _bias[k];
    }
    for (var d = 0; d < dim; d++) {
      final v = pooled[d] / n;
      if (v == 0) continue;
      final row = d * outputs;
      for (var k = 0; k < outputs; k++) {
        logits[k] += v * _kernel[row + k];
      }
    }
    if (activation == 'softmax') {
      var top = logits[0];
      for (final z in logits) {
        if (z > top) top = z;
      }
      var total = 0.0;
      final exps = List<double>.generate(outputs, (k) {
        final e = math.exp(logits[k] - top);
        total += e;
        return e;
      });
      return [for (final e in exps) e / total];
    }
    return [for (final z in logits) 1 / (1 + math.exp(-z))];
  }
}
