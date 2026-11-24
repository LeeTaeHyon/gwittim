import 'package:flutter/widgets.dart';

/// 지금 계정이 게스트(Firebase 익명 계정, D-054)인지 앱 전체에 알린다.
/// 게스트는 크레딧 매일 충전이 없고, 내 정보 계정 칸이 '게스트 끝내기'만 보인다.
class GuestScope extends InheritedWidget {
  const GuestScope({super.key, required this.guest, required super.child});

  final bool guest;

  /// 위에 GuestScope가 없으면(샘플·로컬 서버 모드) 게스트가 아니다.
  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<GuestScope>()?.guest ?? false;

  @override
  bool updateShouldNotify(GuestScope old) => old.guest != guest;
}
