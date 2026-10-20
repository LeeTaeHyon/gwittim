import 'package:flutter/material.dart';

/// D-009 v2 색·글꼴. 화면은 이 값만 쓴다.
abstract final class Gw {
  static const navy = Color(0xFF22306B);
  static const navySoft = Color(0xFFEEF0F7);
  static const lime = Color(0xFFD9F66B);
  static const limeInk = Color(0xFF1C2757);
  static const summary = Color(0xFFF3F9DC);
  static const bg = Color(0xFFF3F4F8);
  static const ink = Color(0xFF161B33);
  static const body = Color(0xFF343A50);
  static const sub = Color(0xFF4F566B);
  static const muted = Color(0xFF646B80);
  static const faint = Color(0xFF9097AB);
  static const line = Color(0xFFE6E8EF);
  static const urgent = Color(0xFFD22030);
  static const urgentSoft = Color(0xFFFFF0F0);
  static const check = Color(0xFFA34700);
  static const checkSoft = Color(0xFFFFF4E0);
  static const checkLine = Color(0xFFFF9500);
  static const checkMark = Color(0xFFFFD9A0);

  static const bubble = BorderRadius.only(
    topLeft: Radius.circular(26),
    topRight: Radius.circular(26),
    bottomRight: Radius.circular(26),
    bottomLeft: Radius.circular(6),
  );
}

/// 라이트 전용 (v2 시안 기준). 어두운 테마는 후속.
ThemeData gwittimTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: Gw.navy,
    primary: Gw.navy,
    onPrimary: Colors.white,
    surface: Colors.white,
    onSurface: Gw.ink,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: 'Pretendard');
  return base.copyWith(
    scaffoldBackgroundColor: Gw.bg,
    textTheme: base.textTheme.apply(bodyColor: Gw.body, displayColor: Gw.ink),
    appBarTheme: const AppBarTheme(
      backgroundColor: Gw.bg,
      foregroundColor: Gw.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(fontFamily: 'Pretendard', fontSize: 20, fontWeight: FontWeight.w700, color: Gw.ink),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: Gw.navySoft,
      labelTextStyle: WidgetStateProperty.all(
        const TextStyle(fontFamily: 'Pretendard', fontSize: 13, fontWeight: FontWeight.w600, color: Gw.body),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Gw.navy,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 56),
        shape: const StadiumBorder(),
        textStyle: base.textTheme.labelLarge!.copyWith(fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: 0),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Gw.ink,
      behavior: SnackBarBehavior.floating,
      shape: StadiumBorder(),
    ),
  );
}
