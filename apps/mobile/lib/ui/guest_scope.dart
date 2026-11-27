import 'package:flutter/widgets.dart';

/// 지금 계정이 게스트(Firebase 익명 계정, D-054)인지, 로그인 표시 이름이 무엇인지 앱 전체에 알린다.
/// 게스트는 크레딧 매일 충전이 없고, 내 정보 계정 칸이 '게스트 끝내기'만 보인다.
/// 표시 이름은 화면에서만 쓴다('OO님 기준'). 서버·AI로 보내지 않는다(report-reminder-spec §4.2).
class GuestScope extends InheritedWidget {
  const GuestScope({super.key, required this.guest, required super.child, this.displayName});

  final bool guest;

  /// 로그인 계정의 표시 이름. 게스트·모르면 null
  final String? displayName;

  /// 위에 GuestScope가 없으면(샘플·로컬 서버 모드) 게스트가 아니다.
  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<GuestScope>()?.guest ?? false;

  /// 표시 이름(앞뒤 공백을 뗀 값). 게스트이거나 비어 있으면 null
  static String? nameOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<GuestScope>();
    if (scope == null || scope.guest) return null;
    final name = scope.displayName?.trim();
    return name == null || name.isEmpty ? null : name;
  }

  @override
  bool updateShouldNotify(GuestScope old) => old.guest != guest || old.displayName != displayName;
}
