import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'auth/auth_gate.dart';
import 'auth/auth_service.dart';
import 'data/api_repository.dart';
import 'data/repository.dart';
import 'ui/briefing_data.dart';
import 'ui/calendar_screen.dart';
import 'ui/common.dart';
import 'ui/components.dart';
import 'ui/home_screen.dart';
import 'ui/icons.dart';
import 'ui/intro.dart';
import 'ui/notices_screen.dart';
import 'ui/profile_screen.dart';
import 'ui/saved_screen.dart';
import 'ui/theme.dart';

// 실행 설정 (--dart-define):
//   GWITTIM_API_BASE  서버 API 주소. 비우면 합성 샘플 자료로 동작한다.
//   GWITTIM_DEV_TOKEN 로컬 개발 서버(backend.api.local)용 토큰. 있으면 Firebase 로그인 없이 그 토큰을 쓴다.
//   둘 다 없고 API 주소만 있으면 Firebase Google 로그인 후 ID 토큰으로 서버를 부른다 (D-004).
const _apiBase = String.fromEnvironment('GWITTIM_API_BASE');
const _devToken = String.fromEnvironment('GWITTIM_DEV_TOKEN');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 화면 설정을 먼저 읽어서 첫 화면부터 고른 테마로 그린다 (D-010).
  final theme = await ThemeController.load(PrefsThemeStore());
  if (_apiBase.isEmpty) {
    _run(GwittimApp(repository: SampleNoticeRepository(), openUrl: _openExternal, themeController: theme));
    return;
  }
  final baseUrl = Uri.parse(_apiBase.endsWith('/') ? _apiBase : '$_apiBase/');
  if (_devToken.isNotEmpty) {
    _run(
      GwittimApp(
        repository: ApiNoticeRepository(baseUrl: baseUrl, tokenProvider: () async => _devToken),
        openUrl: _openExternal,
        themeController: theme,
      ),
    );
    return;
  }
  await Firebase.initializeApp();
  await FirebaseAuthService.initializeGoogle();
  _run(
    AuthGate(
      auth: FirebaseAuthService(),
      repositoryFor: (tokenProvider) => ApiNoticeRepository(baseUrl: baseUrl, tokenProvider: tokenProvider),
      openUrl: _openExternal,
      themeController: theme,
    ),
  );
}

/// 시작 인트로를 씌워 실행한다 (D-011).
void _run(Widget app) => runApp(Intro(child: app));

Future<bool> _openExternal(Uri url) => launchUrl(url, mode: LaunchMode.externalApplication);

/// 라이트·다크 테마와 고른 화면 설정(themeMode)을 연결한 MaterialApp.
class GwMaterialApp extends StatelessWidget {
  const GwMaterialApp({super.key, required this.themeController, required this.home});

  final ThemeController themeController;
  final Widget home;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: themeController,
      builder: (context, mode, child) => MaterialApp(
        title: '귀띔',
        theme: gwittimTheme(),
        darkTheme: gwittimTheme(Brightness.dark),
        themeMode: mode,
        home: child,
      ),
      child: home,
    );
  }
}

class GwittimApp extends StatefulWidget {
  const GwittimApp({
    super.key,
    required this.repository,
    required this.openUrl,
    this.today,
    this.onSignOut,
    this.briefingStore,
    this.themeController,
  });

  final NoticeRepository repository;
  final OpenUrl openUrl;
  final DateTime? today;

  /// 로그인 모드일 때만 있다.
  final Future<void> Function()? onSignOut;

  /// 하루 첫 실행 기록. 기본은 기기 저장소 (D-009).
  final BriefingStore? briefingStore;

  /// 화면(테마) 설정. 없으면 시스템 설정을 따르고 이번 실행에만 기억한다.
  final ThemeController? themeController;

  @override
  State<GwittimApp> createState() => _GwittimAppState();
}

class _GwittimAppState extends State<GwittimApp> {
  ThemeController? _ownTheme;
  late final BriefingStore _briefingStore = widget.briefingStore ?? PrefsBriefingStore();

  ThemeController get _theme => widget.themeController ?? (_ownTheme ??= ThemeController());

  @override
  void dispose() {
    _ownTheme?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GwMaterialApp(
      themeController: _theme,
      home: HomeShell(
        repository: widget.repository,
        openUrl: widget.openUrl,
        today: widget.today,
        onSignOut: widget.onSignOut,
        briefingStore: _briefingStore,
        themeController: _theme,
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.repository,
    required this.openUrl,
    required this.briefingStore,
    required this.themeController,
    this.today,
    this.onSignOut,
  });

  final Future<void> Function()? onSignOut;
  final NoticeRepository repository;
  final OpenUrl openUrl;
  final BriefingStore briefingStore;
  final ThemeController themeController;
  final DateTime? today;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with SingleTickerProviderStateMixin {
  final _homeKey = GlobalKey<HomeScreenState>();
  final _noticesKey = GlobalKey<NoticesScreenState>();
  final _calendarKey = GlobalKey<CalendarScreenState>();
  final _savedKey = GlobalKey<SavedScreenState>();
  int _tab = 0;

  /// 탭을 바꾸는 동안 밀려나는 화면과 방향 (오른쪽 탭으로 가면 1)
  int? _leaving;
  int _direction = 1;

  /// 탭을 바꾸면 지금 화면은 반대쪽으로 밀려나며 흐려지고, 새 화면은 고른 쪽에서 들어온다.
  late final _switch = AnimationController(vsync: this, duration: const Duration(milliseconds: 320), value: 1)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed && _leaving != null) setState(() => _leaving = null);
    });

  void _select(int i) {
    // 저장 상태가 다른 탭에서 바뀔 수 있어 다시 받는다.
    if (i == 2) _calendarKey.currentState?.reload();
    if (i == 3) _savedKey.currentState?.reload();
    if (i == _tab) return;
    final animate = MediaQuery.maybeDisableAnimationsOf(context) != true;
    setState(() {
      _direction = i > _tab ? 1 : -1;
      _leaving = animate ? _tab : null;
      _tab = i;
    });
    if (animate) _switch.forward(from: 0);
  }

  @override
  void dispose() {
    _switch.dispose();
    super.dispose();
  }

  /// 내 정보는 탭이 아니라 홈 머리 오른쪽 버튼으로 연다 (2026-10-25 팀장 결정 Q1 B).
  void _openProfile() {
    Navigator.of(context).push(
      gwRoute(
        context,
        (_) => ProfileScreen(
          repository: widget.repository,
          themeController: widget.themeController,
          onSaved: () {
            _homeKey.currentState?.reload();
            _noticesKey.currentState?.reload();
            _calendarKey.currentState?.reload();
          },
          onSignOut: widget.onSignOut,
        ),
      ),
    );
  }

  /// 탭 화면 하나. 위젯 구조는 늘 같게 두어 화면 상태가 유지된다.
  Widget _page(int i, Widget screen) {
    return Offstage(
      offstage: i != _tab && i != _leaving,
      child: AnimatedBuilder(
        animation: _switch,
        child: screen,
        builder: (context, child) {
          final raw = _switch.value;
          final t = Curves.easeOutCubic.transform(raw);
          final entering = i == _tab;
          final opacity = entering
              ? Curves.easeOut.transform(((raw - 0.2) / 0.8).clamp(0.0, 1.0))
              : 1 - Curves.easeOut.transform((raw / 0.4).clamp(0.0, 1.0));
          final dx = entering ? _direction * 48 * (1 - t) : -_direction * 48 * t;
          return Opacity(
            opacity: i == _tab || i == _leaving ? opacity : 1,
            child: Transform.translate(offset: Offset(i == _tab || i == _leaving ? dx : 0, 0), child: child),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 탭 화면에는 앱 바가 없어서 상태 표시줄 아이콘 색을 직접 맞춘다.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: statusBarStyle(Theme.of(context).brightness),
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              _page(
                0,
                HomeScreen(
                  key: _homeKey,
                  repository: widget.repository,
                  openUrl: widget.openUrl,
                  briefingStore: widget.briefingStore,
                  today: widget.today,
                  onOpenProfile: _openProfile,
                  onShowAll: () => _select(1),
                ),
              ),
              _page(
                1,
                NoticesScreen(
                  key: _noticesKey,
                  repository: widget.repository,
                  openUrl: widget.openUrl,
                  today: widget.today,
                ),
              ),
              _page(
                2,
                CalendarScreen(
                  key: _calendarKey,
                  repository: widget.repository,
                  openUrl: widget.openUrl,
                  today: widget.today,
                ),
              ),
              _page(
                3,
                SavedScreen(
                  key: _savedKey,
                  repository: widget.repository,
                  openUrl: widget.openUrl,
                  today: widget.today,
                  onBrowse: () => _select(1),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: GwTabBar(
          selected: _tab,
          onSelect: _select,
          tabs: const [
            (glyph: GwGlyph.today, label: '오늘'),
            (glyph: GwGlyph.notices, label: '공고'),
            (glyph: GwGlyph.calendar, label: '달력'),
            (glyph: GwGlyph.saved, label: '저장함'),
          ],
        ),
      ),
    );
  }
}
