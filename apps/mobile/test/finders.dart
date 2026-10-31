import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// keepAll이 넣은 보이지 않는 문자(단어 연결자, 줄바꿈 없는 공백)를 빼고 보이는 글자로 찾는다.
String _plain(Text w) => (w.data ?? w.textSpan?.toPlainText() ?? '').replaceAll('\u2060', '').replaceAll('\u00A0', ' ');

Finder findText(String text) =>
    find.byWidgetPredicate((w) => w is Text && _plain(w) == text, description: 'text "$text"');

Finder findTextContaining(String part) =>
    find.byWidgetPredicate((w) => w is Text && _plain(w).contains(part), description: 'text containing "$part"');
