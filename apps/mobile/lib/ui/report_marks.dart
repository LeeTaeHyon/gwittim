import 'package:flutter/widgets.dart';

import 'components.dart';
import 'format.dart';

/// 상세 분석 결과 줄의 형광펜 (report-reminder-spec §4.1).
///
/// 칠하는 것: 날짜·시각, 학생이 이번 요청에서 고른 '해 본 것' 이름, 작은따옴표 인용 '…'(우대 조건).
/// 한 줄에 최대 [maxMarksPerLine]곳(앞에서부터), [maxMarkChars]자를 넘는 조각은 칠하지 않는다
/// (형광펜 조각은 안에서 줄바꿈이 안 된다). 꼬리표와 역량 칩은 호출하는 쪽에서 넘기지 않는다.
const maxMarksPerLine = 2;
const maxMarkChars = 14;

/// 날짜·시각 표기: '2026년 11월 30일', '12월 7일 18시', '12월 7일 18:30', '11.30', 'D-3', '18:00', '오후 6시'
final _dateTime = RegExp(
  r'\d{4}년\s?\d{1,2}월\s?\d{1,2}일(?:\s?\d{1,2}시(?:\s?\d{1,2}분)?|\s?\d{1,2}:\d{2})?'
  r'|\d{1,2}월\s?\d{1,2}일(?:\s?\d{1,2}시(?:\s?\d{1,2}분)?|\s?\d{1,2}:\d{2})?'
  r'|(?<![\d.])(?:0?[1-9]|1[0-2])\.(?:0?[1-9]|[12]\d|3[01])\.?(?![\d.]*\d)(?!\s*(?:학점|점|%|/))'
  r'|(?<![A-Za-z])D-\d+(?!\d)'
  r'|(?<![\d:])\d{1,2}:\d{2}(?![\d:])'
  r'|(?:오전|오후)\s?\d{1,2}시(?:\s?\d{1,2}분)?'
  r'|(?<!\d)\d{1,2}시(?:\s?\d{1,2}분)?(?!간)',
);

/// 작은따옴표 인용. 따옴표 안의 글을 칠하고 따옴표는 그대로 둔다
final _quote = RegExp(r"'([^'\n]+)'");

/// [text]에서 칠할 구간(시작 포함, 끝 제외). 겹치면 앞의 것이 남고, 앞에서부터 최대 2곳.
List<({int start, int end})> reportMarkRanges(String text, {Iterable<String> names = const []}) {
  final found = <({int start, int end})>[];
  for (final m in _dateTime.allMatches(text)) {
    found.add((start: m.start, end: m.end));
  }
  for (final m in _quote.allMatches(text)) {
    found.add((start: m.start + 1, end: m.end - 1));
  }
  for (final name in names.map((n) => n.trim()).where((n) => n.isNotEmpty)) {
    var from = 0;
    while (true) {
      final i = text.indexOf(name, from);
      if (i < 0) break;
      found.add((start: i, end: i + name.length));
      from = i + name.length;
    }
  }
  found.sort((a, b) => a.start != b.start ? a.start.compareTo(b.start) : (b.end - b.start).compareTo(a.end - a.start));
  final out = <({int start, int end})>[];
  var lastEnd = 0;
  for (final r in found) {
    if (r.start < lastEnd) continue; // 겹침: 앞의 것이 남는다
    final piece = text.substring(r.start, r.end);
    if (piece.trim().isEmpty || piece.characters.length > maxMarkChars) continue;
    out.add(r);
    lastEnd = r.end;
    if (out.length == maxMarksPerLine) break;
  }
  return out;
}

/// 줄 글을 형광펜 조각이 섞인 글로. 칠할 곳이 없으면 null(호출하는 쪽이 보통 글로 그린다).
/// 보통 글은 [keepAll]을 줄 전체에 적용한 뒤 구간대로 자른다(어절 단위 줄바꿈 유지).
List<InlineSpan>? markedSpans(String text, TextStyle style, {Iterable<String> names = const []}) {
  final ranges = reportMarkRanges(text, names: names);
  if (ranges.isEmpty) return null;
  final kept = keepAll(text);
  // keepAll이 넣거나 바꾼 것(단어 연결자 U+2060 삽입, 공백 → U+00A0)을 빼고 원래 글자 위치를 찾는다
  final at = <int>[]; // 원래 글 i번째 글자의 kept 안 위치
  for (var k = 0; k < kept.length && at.length < text.length; k++) {
    if (kept[k] == '⁠' && text[at.length] != '⁠') continue;
    at.add(k);
  }
  if (at.length != text.length) return null;
  final spans = <InlineSpan>[];
  var from = 0;
  for (final r in ranges) {
    if (r.start > from) spans.add(TextSpan(text: kept.substring(at[from], at[r.start])));
    spans.add(markSpan(text.substring(r.start, r.end), style));
    from = r.end;
  }
  if (from < text.length) spans.add(TextSpan(text: kept.substring(at[from])));
  return spans;
}
