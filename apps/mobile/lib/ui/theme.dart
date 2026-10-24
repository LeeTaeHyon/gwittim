import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// D-010 색 토큰. 화면은 색을 직접 쓰지 않고 `context.gw`의 역할 이름만 쓴다.
/// 라이트·다크 값은 D-010 표를 따르고, 표에 없는 보조 값은 목업 v2(다크 줄)의 값을 쓴다.
@immutable
class GwColors extends ThemeExtension<GwColors> {
  const GwColors({
    required this.bg,
    required this.card,
    required this.cardSoft,
    required this.neutral,
    required this.ink,
    required this.body,
    required this.sub,
    required this.muted,
    required this.faint,
    required this.line,
    required this.cta,
    required this.onCta,
    required this.point,
    required this.onPoint,
    required this.pointTick,
    required this.accent,
    required this.chip,
    required this.onChip,
    required this.lime,
    required this.limeInk,
    required this.marker,
    required this.summary,
    required this.urgent,
    required this.urgentSoft,
    required this.urgentFill,
    required this.onUrgentFill,
    required this.check,
    required this.checkSoft,
    required this.checkBox,
    required this.checkLine,
    required this.checkMark,
    required this.toast,
    required this.onToast,
    required this.loginBg,
    required this.loginCard,
    required this.loginSub,
    required this.loginInk,
    required this.tab,
    required this.onTab,
    required this.tabShadow,
  });

  /// 바탕
  final Color bg;

  /// 카드·시트
  final Color card;

  /// 카드 안의 옅은 상자 (계정 정보)
  final Color cardSoft;

  /// 중립 칩·세그먼트 바탕
  final Color neutral;

  /// 제목 / 본문 / 보조 글자. 보조 글자도 카드 바탕 대비 4.5:1 이상.
  final Color ink;
  final Color body;
  final Color sub;
  final Color muted;

  /// 장식용(화살표·지난 일정 점). 글자에는 쓰지 않는다.
  final Color faint;

  /// 구분선
  final Color line;

  /// 큰 버튼 (라이트 네이비, 다크 라임)
  final Color cta;
  final Color onCta;

  /// 체크 상자·오늘 날짜·저장됨 아이콘 (라이트 네이비, 다크 라임). 면으로만 쓴다.
  final Color point;
  final Color onPoint;

  /// point 위의 체크 표시
  final Color pointTick;

  /// 강조 글자 (조건 충족 등)
  final Color accent;

  /// 보조 버튼·칩
  final Color chip;
  final Color onChip;

  /// '귀띔' 배지 바탕과 글자. 라임은 면으로만 쓴다.
  final Color lime;
  final Color limeInk;

  /// 형광펜 (다크는 라임 28% 투명)
  final Color marker;

  /// 한 줄 요약 말풍선
  final Color summary;

  /// 급한 마감 글자 / 바탕 / 채운 면과 그 위 글자
  final Color urgent;
  final Color urgentSoft;
  final Color urgentFill;
  final Color onUrgentFill;

  /// 확인 필요 글자 / 바탕 (리포트 체크리스트에서만, 목록은 회색 — D-009)
  final Color check;
  final Color checkSoft;
  final Color checkBox;
  final Color checkLine;
  final Color checkMark;

  /// 알림(토스트)
  final Color toast;
  final Color onToast;

  /// 로그인 화면 바탕, 예시 말풍선, 보조 글자
  final Color loginBg;
  final Color loginCard;
  final Color loginSub;

  /// 로그인 바탕 위 제목·링크
  final Color loginInk;

  /// 떠 있는 탭 막대 바탕, 고르지 않은 탭 글자, 그림자. 고른 탭은 라임 면이다.
  final Color tab;
  final Color onTab;
  final Color tabShadow;

  static const light = GwColors(
    bg: Color(0xFFF3F4F8),
    card: Color(0xFFFFFFFF),
    cardSoft: Color(0xFFF7F8FB),
    neutral: Color(0xFFF3F4F8),
    ink: Color(0xFF161B33),
    body: Color(0xFF343A50),
    sub: Color(0xFF4F566B),
    muted: Color(0xFF646B80),
    faint: Color(0xFFB3B8C8),
    line: Color(0xFFE6E8EF),
    cta: _navy,
    onCta: Color(0xFFFFFFFF),
    point: _navy,
    onPoint: Color(0xFFFFFFFF),
    pointTick: _lime,
    accent: Color(0xFF3446A8),
    chip: Color(0xFFEEF0F7),
    onChip: _navy,
    lime: _lime,
    limeInk: _limeInk,
    marker: _lime,
    summary: Color(0xFFF3F9DC),
    urgent: Color(0xFFD22030),
    urgentSoft: Color(0xFFFFF0F0),
    urgentFill: Color(0xFFD22030),
    onUrgentFill: Color(0xFFFFFFFF),
    check: Color(0xFFA34700),
    checkSoft: Color(0xFFFFF4E0),
    checkBox: Color(0xFFFFF7EA),
    checkLine: Color(0xFFFF9500),
    checkMark: Color(0xFFFFD9A0),
    toast: Color(0xFF161B33),
    onToast: Color(0xFFFFFFFF),
    loginBg: _navy,
    loginCard: Color(0xFFFFFFFF),
    loginSub: Color(0xFFC9CFEA),
    loginInk: Color(0xFFFFFFFF),
    tab: _navy,
    onTab: Color(0xFFC9CFEA),
    tabShadow: Color(0x47161F4A), // 28%
  );

  static const dark = GwColors(
    bg: Color(0xFF0F1222),
    card: Color(0xFF191D33),
    cardSoft: Color(0xFF20253F),
    neutral: Color(0xFF232845),
    ink: Color(0xFFEEF0F8),
    body: Color(0xFFD3D7E8),
    sub: Color(0xFFB0B6CC),
    muted: Color(0xFF8C93AE),
    faint: Color(0xFF5C6380),
    line: Color(0xFF2C3150),
    cta: _lime,
    onCta: Color(0xFF161B33),
    point: _lime,
    onPoint: Color(0xFF161B33),
    pointTick: Color(0xFF161B33),
    accent: Color(0xFFA9B8FF),
    chip: Color(0xFF262C4D),
    onChip: Color(0xFFC9D2FF),
    lime: _lime,
    limeInk: _limeInk,
    marker: Color(0x47D9F66B), // 라임 28%
    summary: Color(0xFF262E1B),
    urgent: Color(0xFFFF6B76),
    urgentSoft: Color(0xFF3A1F2A),
    urgentFill: Color(0xFFFF6B76),
    onUrgentFill: Color(0xFF1A0B10),
    check: Color(0xFFFFB45C),
    checkSoft: Color(0xFF3A2B16),
    checkBox: Color(0xFF33270F),
    checkLine: Color(0xFFFF9F1A),
    checkMark: Color(0x4DFFB45C),
    toast: Color(0xFFEEF0F8),
    onToast: Color(0xFF161B33),
    loginBg: Color(0xFF0F1222),
    loginCard: Color(0xFF191D33),
    loginSub: Color(0xFFB9C2EE),
    loginInk: Color(0xFFFFFFFF),
    tab: Color(0xFF272D52),
    onTab: Color(0xFFA3A9C2),
    tabShadow: Color(0x80000000), // 50%
  );

  static const _navy = Color(0xFF22306B);
  static const _lime = Color(0xFFD9F66B);
  static const _limeInk = Color(0xFF1C2757);

  List<Color> get _all => [
    bg, card, cardSoft, neutral, ink, body, sub, muted, faint, line, cta, onCta, point, onPoint, pointTick, //
    accent, chip, onChip, lime, limeInk, marker, summary, urgent, urgentSoft, urgentFill, onUrgentFill, //
    check, checkSoft, checkBox, checkLine, checkMark, toast, onToast, loginBg, loginCard, loginSub, loginInk, //
    tab, onTab, tabShadow,
  ];

  static GwColors _fromList(List<Color> c) {
    var i = 0;
    Color next() => c[i++];
    return GwColors(
      bg: next(),
      card: next(),
      cardSoft: next(),
      neutral: next(),
      ink: next(),
      body: next(),
      sub: next(),
      muted: next(),
      faint: next(),
      line: next(),
      cta: next(),
      onCta: next(),
      point: next(),
      onPoint: next(),
      pointTick: next(),
      accent: next(),
      chip: next(),
      onChip: next(),
      lime: next(),
      limeInk: next(),
      marker: next(),
      summary: next(),
      urgent: next(),
      urgentSoft: next(),
      urgentFill: next(),
      onUrgentFill: next(),
      check: next(),
      checkSoft: next(),
      checkBox: next(),
      checkLine: next(),
      checkMark: next(),
      toast: next(),
      onToast: next(),
      loginBg: next(),
      loginCard: next(),
      loginSub: next(),
      loginInk: next(),
      tab: next(),
      onTab: next(),
      tabShadow: next(),
    );
  }

  /// 토큰은 고정 값이라 바꿔 만들 일이 없다.
  @override
  GwColors copyWith() => this;

  /// 테마가 바뀔 때 Material 색과 함께 부드럽게 바뀐다.
  @override
  GwColors lerp(GwColors? other, double t) {
    if (other == null) return this;
    final a = _all;
    final b = other._all;
    return _fromList([for (var i = 0; i < a.length; i++) Color.lerp(a[i], b[i], t)!]);
  }
}

extension GwContext on BuildContext {
  GwColors get gw => Theme.of(this).extension<GwColors>() ?? GwColors.light;
}

/// 색이 아닌 공통 모양
abstract final class Gw {
  static const bubble = BorderRadius.only(
    topLeft: Radius.circular(26),
    topRight: Radius.circular(26),
    bottomRight: Radius.circular(26),
    bottomLeft: Radius.circular(6),
  );
}

ThemeData gwittimTheme([Brightness brightness = Brightness.light]) {
  final c = brightness == Brightness.dark ? GwColors.dark : GwColors.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: GwColors._navy,
    brightness: brightness,
    primary: c.cta,
    onPrimary: c.onCta,
    secondaryContainer: c.chip,
    onSecondaryContainer: c.onChip,
    surface: c.card,
    onSurface: c.ink,
    onSurfaceVariant: c.muted,
    outline: c.muted,
    outlineVariant: c.line,
    error: c.urgent,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: 'Pretendard');
  return base.copyWith(
    extensions: [c],
    scaffoldBackgroundColor: c.bg,
    dividerColor: c.line,
    textTheme: base.textTheme.apply(bodyColor: c.body, displayColor: c.ink),
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(fontFamily: 'Pretendard', fontSize: 20, fontWeight: FontWeight.w700, color: c.ink),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.card,
      indicatorColor: c.chip,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(color: states.contains(WidgetState.selected) ? c.onChip : c.muted),
      ),
      labelTextStyle: WidgetStateProperty.all(
        TextStyle(fontFamily: 'Pretendard', fontSize: 13, fontWeight: FontWeight.w600, color: c.body),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.cta,
        foregroundColor: c.onCta,
        minimumSize: const Size(0, 56),
        shape: const StadiumBorder(),
        textStyle: base.textTheme.labelLarge!.copyWith(fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: 0),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: c.card, dragHandleColor: c.faint),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.toast,
      contentTextStyle: TextStyle(fontFamily: 'Pretendard', fontSize: 15, fontWeight: FontWeight.w600, color: c.onToast),
      behavior: SnackBarBehavior.floating,
      shape: const StadiumBorder(),
    ),
  );
}

/// 앱 바가 없는 화면의 상태 표시줄. 바탕이 어두우면 밝은 아이콘.
SystemUiOverlayStyle statusBarStyle(Brightness background) => SystemUiOverlayStyle(
  statusBarColor: const Color(0x00000000),
  statusBarIconBrightness: background == Brightness.dark ? Brightness.light : Brightness.dark,
  statusBarBrightness: background,
);

/// 프로필의 '화면' 설정. 기기에만 저장한다 (D-010).
abstract class ThemeStore {
  Future<ThemeMode> read();
  Future<void> write(ThemeMode mode);
}

class PrefsThemeStore implements ThemeStore {
  static const key = 'theme_mode';

  @override
  Future<ThemeMode> read() async {
    final name = (await SharedPreferences.getInstance()).getString(key);
    return ThemeMode.values.where((m) => m.name == name).firstOrNull ?? ThemeMode.system;
  }

  @override
  Future<void> write(ThemeMode mode) async => (await SharedPreferences.getInstance()).setString(key, mode.name);
}

class MemoryThemeStore implements ThemeStore {
  MemoryThemeStore([this._mode = ThemeMode.system]);

  ThemeMode _mode;

  @override
  Future<ThemeMode> read() async => _mode;

  @override
  Future<void> write(ThemeMode mode) async => _mode = mode;
}

/// 고른 테마. 앱 시작 때 읽고(load), 바꾸면 바로 화면에 적용한 뒤 저장한다.
class ThemeController extends ValueNotifier<ThemeMode> {
  ThemeController({ThemeStore? store, ThemeMode initial = ThemeMode.system})
    : _store = store ?? MemoryThemeStore(initial),
      super(initial);

  final ThemeStore _store;

  /// 기기 저장소를 못 읽으면 시스템 설정으로 시작한다.
  static Future<ThemeController> load(ThemeStore store) async {
    var mode = ThemeMode.system;
    try {
      mode = await store.read();
    } catch (_) {}
    return ThemeController(store: store, initial: mode);
  }

  Future<void> select(ThemeMode mode) async {
    value = mode;
    try {
      await _store.write(mode);
    } catch (_) {
      // 저장하지 못해도 이번 실행에는 적용된다.
    }
  }
}
