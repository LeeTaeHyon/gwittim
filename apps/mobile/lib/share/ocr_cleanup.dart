// 캡처 글자 인식 결과 정리 (기기 안, 확인 화면에 넣기 전). 순수 함수라 ML Kit 없이 시험한다.
// 카톡 화면 캡처에는 상태 표시줄·상단 바·하단 메뉴가 같이 찍히고, 한 문장이 줄바꿈으로 쪼개지며,
// 이모지는 엉뚱한 글자로 읽히고, 가려진 보낸 이름이 글자로 읽힌다.
// 위·아래 제외 비율은 실제 캡처 1장(1440x3120, 갤럭시 카톡 공지)으로 맞춘 값이다. 다른 기기·앱 배율에서는 달라질 수 있다.

/// 줄 안의 한 단어(ML Kit element) 또는 글자(symbol)와 위치(픽셀), 신뢰도(없으면 null).
class OcrWord {
  const OcrWord(
    this.text, {
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    this.confidence,
    this.symbols = const [],
  });

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;
  final double? confidence;

  /// 글자 하나하나(ML Kit symbol, Android만). 없을 수 있다.
  final List<OcrWord> symbols;
}

/// 인식된 한 줄과 그 위치(픽셀).
class OcrLine {
  const OcrLine(
    this.text, {
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    this.words = const [],
  });

  /// 줄을 이루는 단어들(없을 수 있다)
  final List<OcrWord> words;

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get height => bottom - top;
  double get centerY => (top + bottom) / 2;

  OcrLine copyWith({String? text, List<OcrWord>? words}) => OcrLine(
    text ?? this.text,
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    words: words ?? this.words,
  );
}

/// 카톡 화면 요소 문구(공고 본문이 아님)
const _chromePhrases = [
  '채널 추가',
  '알림톡 차단',
  '채널 홈',
  '바로가기',
  '메시지 메뉴',
  '차단하기',
  '신고하기',
  '메시지를 입력',
];

final _timeOnly = RegExp(r'^\d{1,2}\s*:\s*\d{2}$');
final _timeLead = RegExp(r'^\d{1,2}\s*:\s*\d{2}\b');
final _backBar = RegExp(r'^[←<‹〈]');
final _hangul = RegExp(r'[가-힣]');
final _letterOrDigit = RegExp(r'[가-힣A-Za-z]');
final _bullet = RegExp(r'^\s*([-–·•○●▶▷■□◆◇※*]|\d{1,2}[.)]|[①-⑩]|\[|【|<)');

/// '교육기간:', '참가비:', '문의 :' 같은 항목명(한글 2~6자 + 콜론)으로 시작하는 줄
final _labelStart = RegExp(r'^\s*[가-힣]{2,6}\s*:');

bool _isChrome(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return true;
  if (_timeOnly.hasMatch(t)) return true;
  // '8:54 ALIR)' 같은 상태 표시줄 조각
  if (_timeLead.hasMatch(t) &&
      t.length <= 14 &&
      _hangul.allMatches(t).length < 3) {
    return true;
  }
  if (_backBar.hasMatch(t) && t.length <= 24) return true;
  for (final p in _chromePhrases) {
    if (t.contains(p) && t.length <= p.length + 8) return true;
  }
  // 기호·숫자만 있는 짧은 줄('.l 88')
  if (t.length <= 8 && !_hangul.hasMatch(t) && !_letterOrDigit.hasMatch(t)) {
    return true;
  }
  if (t.length <= 6 &&
      !_hangul.hasMatch(t) &&
      RegExp(r'^[\W\dlI|]+$').hasMatch(t)) {
    return true;
  }
  return false;
}

// ── 한글 자모 비교 (가려진 보낸 이름 줄 찾기) ──

const _cho = 'ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ';
const _jung = 'ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ';
const _jong = ' ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ';

/// 한글 음절을 자모로 푼다. 한글이 아닌 글자는 그대로 둔다.
List<String> _jamo(String s) {
  final out = <String>[];
  for (final r in s.runes) {
    if (r >= 0xAC00 && r <= 0xD7A3) {
      final i = r - 0xAC00;
      out.add(_cho[i ~/ 588]);
      out.add(_jung[(i % 588) ~/ 28]);
      final j = i % 28;
      if (j != 0) out.add(_jong[j]);
    } else {
      out.add(String.fromCharCode(r));
    }
  }
  return out;
}

/// 자모 단위 편집 거리로 잰 비슷한 정도(0~1)
double jamoSimilarity(String a, String b) {
  final x = _jamo(a), y = _jamo(b);
  if (x.isEmpty || y.isEmpty) return 0;
  var prev = List<int>.generate(y.length + 1, (i) => i);
  for (var i = 1; i <= x.length; i++) {
    final cur = List<int>.filled(y.length + 1, 0)..[0] = i;
    for (var j = 1; j <= y.length; j++) {
      final cost = x[i - 1] == y[j - 1] ? 0 : 1;
      cur[j] = [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost].reduce(
        (m, v) => v < m ? v : m,
      );
    }
    prev = cur;
  }
  final longest = x.length > y.length ? x.length : y.length;
  return 1 - prev.last / longest;
}

/// 상단 채널 이름 줄('← 명지전문대학 공지사항')에서 이름 후보를 뽑는다(화살표·기호 뺀 단어들).
/// 기기마다 화살표가 따로 읽히거나 빠지므로, 화살표 줄이 없으면 '공지사항'·'채널'이 든 줄이나
/// 위쪽 제외 영역([topLimit] 위)의 한글 줄에서도 찾는다.
List<String> _channelNames(List<OcrLine> all, {double? topLimit}) {
  List<String> words(String t) => t
      .replaceFirst(_backBar, '')
      .split(RegExp(r'\s+'))
      .where((w) => w.length >= 3 && _hangul.hasMatch(w))
      .toList();
  for (final l in all) {
    final t = l.text.trim();
    if (!_backBar.hasMatch(t)) continue;
    final names = words(t);
    if (names.isNotEmpty) return names;
  }
  final names = <String>[];
  for (final l in all) {
    final t = l.text.trim();
    final top = topLimit != null && l.centerY < topLimit;
    if ((top || t.contains('공지사항')) && !_isChrome(t)) names.addAll(words(t));
  }
  return names;
}

/// 줄 글자들의 평균 신뢰도. 모르면 null
double? _lineConfidence(OcrLine l) {
  final cs = [
    for (final w in l.words)
      for (final s in w.symbols)
        if (s.confidence != null) s.confidence!,
  ];
  if (cs.isEmpty) return null;
  return cs.reduce((a, b) => a + b) / cs.length;
}

/// 채널 이름과 자모가 비슷한 공백 없는 짧은 한글 줄이면 가려진 보낸 이름 줄이다.
/// 반쯤 가려진 줄은 기기마다 다르게 읽힌다('명시선문내악', '멍시선분내악'). 채널 이름도 '명자전문대학'처럼
/// 틀릴 수 있어 기준을 0.5로 둔다. 이름을 못 찾았으면 글자 신뢰도가 낮은(0.5 미만) 줄만 뺀다.
bool _looksLikeSenderName(OcrLine line, List<String> names) {
  final t = line.text.trim();
  if (t.length < 3 || t.length > 14 || RegExp(r'[\s\d]').hasMatch(t)) {
    return false;
  }
  if (_hangul.allMatches(t).length != t.length) return false;
  for (final n in names) {
    if (jamoSimilarity(t, n) >= 0.5) return true;
  }
  final c = _lineConfidence(line);
  return names.isEmpty && c != null && c < 0.5;
}

// ── 이모지 자리 글자 ──

/// 줄 맨 앞의 이모지를 잘못 읽은 1글자 조각을 지운다.
/// 첫 글자가 신뢰도 [lowConfidence] 미만이고, 한글·기호 1글자이며, 뒤 글자와 간격이 벌어져 있을 때만 지운다.
/// 숫자·영문은 지우지 않고, 간격이 붙어 있는 정상 단어의 첫 글자도 지우지 않는다.
OcrLine _stripLeadingJunk(OcrLine l, {double lowConfidence = 0.5}) {
  if (l.words.isEmpty) return l;
  final first = l.words.first;
  if (first.symbols.isEmpty) return l;
  final s0 = first.symbols.first;
  final conf = s0.confidence;
  if (conf == null || conf >= lowConfidence) return l;
  if (s0.text.runes.length != 1 || RegExp(r'[0-9A-Za-z]').hasMatch(s0.text)) {
    return l;
  }
  OcrWord? next;
  if (first.symbols.length > 1) {
    next = first.symbols[1];
  } else if (l.words.length > 1 && l.words[1].symbols.isNotEmpty) {
    next = l.words[1].symbols.first;
  }
  if (next == null) return l;
  final glyph = s0.right - s0.left;
  final gap = next.left - s0.right;
  // 이모지 조각은 뒤 본문 글자와 한 글자 너비 가까이 떨어져 있다
  if (gap < (glyph * 0.25 < 8 ? 8 : glyph * 0.25)) return l;
  final text = l.text.trimLeft();
  if (!text.startsWith(s0.text)) return l;
  final rest = text.substring(s0.text.length).trimLeft();
  if (rest.runes.length < 2) return l;
  final words = [...l.words];
  if (first.symbols.length > 1) {
    words[0] = OcrWord(
      first.text.substring(s0.text.length),
      left: next.left,
      top: first.top,
      right: first.right,
      bottom: first.bottom,
      confidence: first.confidence,
      symbols: first.symbols.sublist(1),
    );
  } else {
    words.removeAt(0);
  }
  return l.copyWith(text: rest, words: words);
}

/// [lines]를 위에서 아래로 정리해 본문 글로 만든다.
/// [imageHeight]를 알면 위·아래 가장자리 줄을 뺀다. 모르면(null) 위치로는 거르지 않는다.
/// 기본 비율은 1440x3120 카톡 캡처 기준: 상태 표시줄·상단 바(중심 높이 1~8%)와 '채널 추가' 바(13%) 위쪽까지를
/// 위 10%로 자르고, 아래 '채널 홈 바로가기' 바(중심 95.5%)와 본문 마지막 줄(91%) 사이인 93.5% 아래를 뺀다.
String cleanOcrLines(
  List<OcrLine> lines, {
  double? imageHeight,
  double topRatio = 0.10,
  double bottomRatio = 0.935,
}) {
  final sorted = [...lines]..sort((a, b) => a.top.compareTo(b.top));
  // 채널 이름은 위쪽 제외 영역의 줄에서도 비교용으로 쓴다
  final names = _channelNames(
    sorted,
    topLimit: imageHeight != null && imageHeight > 0 ? imageHeight * topRatio : null,
  );
  final kept = <OcrLine>[];
  for (final l in sorted) {
    if (imageHeight != null && imageHeight > 0) {
      final r = l.centerY / imageHeight;
      if (r < topRatio || r > bottomRatio) continue;
    }
    if (_isChrome(l.text)) continue;
    kept.add(_stripLeadingJunk(l.copyWith(text: l.text.trim())));
  }
  // 정리 뒤 첫 줄이 가려진 보낸 이름이면 뺀다
  if (kept.isNotEmpty && _looksLikeSenderName(kept.first, names)) {
    kept.removeAt(0);
  }
  if (kept.isEmpty) return '';
  final maxRight = kept.map((l) => l.right).reduce((a, b) => a > b ? a : b);

  final out = <OcrLine>[];
  for (final l in kept) {
    if (out.isNotEmpty && _continues(out.last, l, maxRight)) {
      final p = out.removeLast();
      out.add(
        OcrLine(
          '${p.text} ${l.text}',
          left: p.left < l.left ? p.left : l.left,
          top: p.top,
          right: p.right > l.right ? p.right : l.right,
          bottom: l.bottom,
        ),
      );
    } else {
      out.add(l);
    }
  }
  return out.map((l) => l.text).join('\n');
}

/// [next]가 [prev]와 같은 문단에서 줄바꿈으로 쪼개진 줄인지
bool _continues(OcrLine prev, OcrLine next, double maxRight) {
  if (_bullet.hasMatch(next.text)) return false;
  if (_labelStart.hasMatch(next.text)) return false; // '운영기관:' 같은 항목은 새 줄
  final h = prev.height <= 0 ? 1.0 : prev.height;
  final gap = next.top - prev.bottom;
  if (gap > h * 0.9) return false; // 문단 사이 빈 줄
  // 이전 줄이 문장·항목을 끝냈으면 새 줄
  if (RegExp(r'[.!?:;]$|다\.$').hasMatch(prev.text)) return false;
  // 제목 다음 줄이 '안내'처럼 아주 짧으면 합침
  if (next.text.length <= 4 && gap <= h * 0.6) return true;
  // 이전 줄이 오른쪽 끝까지 찬 줄이면 자동 줄바꿈으로 본다
  final width = maxRight - prev.left;
  if (width > 0 && prev.right >= maxRight - width * 0.06 && gap <= h * 0.6) {
    return true;
  }
  return false;
}
