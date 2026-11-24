import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../data/models.dart';

/// '다음에도 이대로'로 고른 상세 분석 질문 답. 기기에만 둔다 (docs/agent-privacy-spec.md §2.2).
/// 서버로는 분석을 요청할 때만 보내고 저장하지 않는다.
abstract class AgentChipStore {
  /// 저장한 답. 없으면 null
  Future<AnalysisChips?> read();

  /// null이면 지운다.
  Future<void> write(AnalysisChips? chips);
}

class PrefsAgentChipStore implements AgentChipStore {
  static const key = 'agent_chips';

  @override
  Future<AnalysisChips?> read() async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    if (raw == null) return null;
    try {
      return AnalysisChips.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null; // 읽지 못하면 저장하지 않은 것으로 본다
    }
  }

  @override
  Future<void> write(AnalysisChips? chips) async {
    final prefs = await SharedPreferences.getInstance();
    if (chips == null || chips.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, jsonEncode(chips.toJson()));
    }
  }
}

class MemoryAgentChipStore implements AgentChipStore {
  MemoryAgentChipStore([this._chips]);

  AnalysisChips? _chips;

  @override
  Future<AnalysisChips?> read() async => _chips;

  @override
  Future<void> write(AnalysisChips? chips) async => _chips = chips == null || chips.isEmpty ? null : chips;
}

/// 분석 요청마다 새로 만드는 요청 id. 재시도 때만 같은 값을 쓴다.
String newRequestId() {
  final random = Random.secure();
  return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// '11월 19일 09:42' (기기 시간대)
String shortDateTime(DateTime at) {
  final t = at.toLocal();
  return '${t.month}월 ${t.day}일 ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// 게스트(익명 계정, D-054)의 크레딧 안내. 게스트는 매일 충전이 없다.
const guestNoRefillText = '게스트는 매일 충전이 없습니다. Google 계정으로 시작하면 매일 1개가 충전됩니다.';

/// 크레딧 페이지의 다음 충전 문구 (명세 §10.2). 충전은 다음 날 0시(KST)다.
String nextRefillText(Credits credits, {DateTime? now, bool guest = false}) {
  if (guest) return guestNoRefillText;
  final next = credits.nextRefillAt;
  if (next == null) return '최대 보유. 사용하면 다음 날부터 다시 충전됩니다.';
  DateTime kst(DateTime d) => d.toUtc().add(const Duration(hours: 9));
  final n = kst(next);
  final t = kst(now ?? DateTime.now());
  final tomorrow = DateTime.utc(t.year, t.month, t.day + 1);
  final when = DateTime.utc(n.year, n.month, n.day) == tomorrow ? '내일' : '${n.month}월 ${n.day}일';
  return '다음 충전: $when ${n.hour}시 (+1)';
}
