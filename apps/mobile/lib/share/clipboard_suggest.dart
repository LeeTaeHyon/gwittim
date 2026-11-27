import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'share_prepare.dart';

// 복사한 글 자동 제안 (D-062). 클립보드 내용은 기기에서만 다루고, 사용자가 [불러오기]를 누르기 전에는 서버로 보내지 않는다.

/// 클립보드 읽기. Android 12+는 내용을 읽을 때 시스템 '붙여넣음' 알림이 뜨므로 있는지(hasStrings)부터 본다.
abstract class ClipboardSource {
  Future<bool> hasStrings();
  Future<String?> readText();
}

class SystemClipboardSource implements ClipboardSource {
  @override
  Future<bool> hasStrings() => Clipboard.hasStrings();

  @override
  Future<String?> readText() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;
}

/// 이미 불러왔거나 닫은 글의 해시(가린 본문 기준)를 기기에만 최근 20개 남긴다.
abstract class SuggestMemory {
  Future<List<String>> read();
  Future<void> write(List<String> hashes);
}

class PrefsSuggestMemory implements SuggestMemory {
  static const key = 'share_clip_seen';

  @override
  Future<List<String>> read() async =>
      (await SharedPreferences.getInstance()).getStringList(key) ?? const [];

  @override
  Future<void> write(List<String> hashes) async =>
      (await SharedPreferences.getInstance()).setStringList(key, hashes);
}

class MemorySuggestMemory implements SuggestMemory {
  MemorySuggestMemory([List<String>? initial]) : _v = [...?initial];

  List<String> _v;

  @override
  Future<List<String>> read() async => _v;

  @override
  Future<void> write(List<String> hashes) async => _v = [...hashes];
}

class ClipSuggestion {
  const ClipSuggestion({required this.text, required this.hash});

  /// 내용을 아직 읽지 않은 제안(iOS). [불러오기]를 누를 때 읽는다.
  const ClipSuggestion.unread() : text = null, hash = null;

  final String? text;
  final String? hash;

  bool get unread => text == null;

  /// 카드에 보일 첫 줄(비어 있지 않은 첫 줄). 아직 읽지 않았으면 null
  String? get firstLine => text
      ?.split('\n')
      .map((e) => e.trim())
      .firstWhere((e) => e.isNotEmpty, orElse: () => '');
}

final _noticeWords = RegExp(
  r'까지|모집|신청|안내|접수|마감|\d{1,2}\s*월\s*\d{1,2}\s*일|\d{1,2}/\d{1,2}|\d{4}[.\-]\d{1,2}[.\-]\d{1,2}',
);

/// 공고처럼 보이는지: 20자 이상, 날짜·까지·모집·신청·안내 같은 말이 있고, 개인 알림·잡음이 아님
bool looksLikeNotice(String text) {
  final prep = prepareShare(text);
  if (prep.tooShort || prep.tooLong || prep.isPersonal) return false;
  return _noticeWords.hasMatch(prep.cleaned);
}

/// 같은 글인지 가르는 짧은 해시(FNV-1a 64비트, 공백 정리 뒤 가린 본문). 보안 용도가 아니다.
String clipHash(String masked) {
  final s = masked.replaceAll(RegExp(r'\s+'), ' ').trim();
  var h = BigInt.parse('cbf29ce484222325', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16);
  final mask = (BigInt.one << 64) - BigInt.one;
  for (final u in s.codeUnits) {
    h = ((h ^ BigInt.from(u)) * prime) & mask;
  }
  return h.toRadixString(16);
}

class ClipboardSuggester {
  ClipboardSuggester({ClipboardSource? clipboard, SuggestMemory? memory, bool? readOnCheck})
    : clipboard = clipboard ?? SystemClipboardSource(),
      memory = memory ?? PrefsSuggestMemory(),
      readOnCheck = readOnCheck ?? defaultTargetPlatform != TargetPlatform.iOS;

  final ClipboardSource clipboard;
  final SuggestMemory memory;

  /// 앱을 열 때 내용까지 읽을지. iOS 16+는 다른 앱이 복사한 글을 읽을 때마다 '붙여넣기 허용' 창을 띄우므로
  /// iOS에서는 있는지(hasStrings, 창 없음)만 보고, 내용은 사용자가 [불러오기]를 누를 때 읽는다.
  final bool readOnCheck;
  static const limit = 20;

  /// 제안할 글이 있으면 돌려준다. 내용은 hasStrings가 true일 때만 읽는다.
  Future<ClipSuggestion?> check() async {
    try {
      if (!await clipboard.hasStrings()) return null;
      if (!readOnCheck) return const ClipSuggestion.unread();
      final text = await clipboard.readText();
      if (text == null || !looksLikeNotice(text)) return null;
      final hash = clipHash(prepareShare(text).masked);
      if ((await memory.read()).contains(hash)) return null;
      return ClipSuggestion(text: text, hash: hash);
    } catch (_) {
      return null; // 읽지 못하면 제안하지 않는다
    }
  }

  /// [불러오기] 때 내용을 읽는다(아직 읽지 않은 제안이면 여기서 처음 읽는다). 비었으면 null
  Future<String?> readFor(ClipSuggestion s) async {
    if (!s.unread) return s.text;
    try {
      final text = await clipboard.readText();
      return text == null || text.trim().isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  /// 불러왔거나 닫은 글을 다시 제안하지 않도록 기억한다.
  Future<void> remember(String hash) async {
    try {
      final list = [...await memory.read()]..remove(hash);
      list.add(hash);
      await memory.write(
        list.length > limit ? list.sublist(list.length - limit) : list,
      );
    } catch (_) {
      // 기기 저장소를 못 쓰면 다음에 한 번 더 보일 수 있다
    }
  }
}
