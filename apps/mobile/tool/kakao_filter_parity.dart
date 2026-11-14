// 기기 안 알림톡 종류 판정·가림(lib/classifier/kakao_filter.dart)을 카톡 내보내기 메시지 전체로 파서와 비교한다.
// 파일은 쓰지 않는다. 다른 메시지는 번호와 칸 이름만 출력한다(원문은 화면에 내지 않음).
//
// 먼저 저장소 루트에서:  uv run python tools/dump_kakao_filter.py
// 그다음 apps/mobile에서: dart run tool/kakao_filter_parity.dart [기준값 경로]
import 'dart:convert';
import 'dart:io';

import 'package:gwittim/classifier/kakao_filter.dart';

void main(List<String> args) {
  final path = args.isNotEmpty ? args[0] : '../../data/local/kakao_filter_server.jsonl';
  final lines = File(path).readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
  final header = jsonDecode(lines.first) as Map<String, dynamic>;
  final rows = [for (final l in lines.skip(1)) jsonDecode(l) as Map<String, dynamic>];

  final serverNames = (header['names'] as List).cast<String>().toSet();
  final cleaned = [for (final r in rows) cleanBody(r['raw'] as String)];
  final names = detectNames(cleaned);
  final sameNames = names.length == serverNames.length && names.containsAll(serverNames);

  final same = {'clean': 0, 'kind': 0, 'masked': 0, 'title': 0};
  final different = <String>[];
  final kinds = <String, int>{};
  for (final (i, r) in rows.indexed) {
    final clean = cleaned[i];
    final kind = kakaoKind(clean, names);
    final masked = maskPersonal(clean, names);
    final title = kakaoTitle(masked, r['room'] as String);
    kinds[r['kind'] as String] = (kinds[r['kind'] as String] ?? 0) + 1;
    final got = {'clean': clean, 'kind': kind, 'masked': masked, 'title': title};
    final wrong = [
      for (final k in same.keys)
        if (got[k] == r[k]) k else '!$k',
    ].where((k) => k.startsWith('!')).toList();
    for (final k in same.keys) {
      if (got[k] == r[k]) same[k] = same[k]! + 1;
    }
    if (wrong.isNotEmpty) different.add('$i(${wrong.map((k) => k.substring(1)).join(',')})');
  }

  final n = rows.length;
  stdout.writeln('메시지 $n건, 파서 종류 분포 $kinds');
  stdout.writeln('받는 사람 이름 목록: ${sameNames ? '같음' : '다름'} (${names.length}개)');
  for (final e in same.entries) {
    stdout.writeln('${e.key} 일치 ${e.value}/$n');
  }
  if (different.isNotEmpty) stdout.writeln('다른 메시지(번호): ${different.take(30).join(' ')}');
  exitCode = different.isEmpty && sameNames ? 0 : 1;
}
