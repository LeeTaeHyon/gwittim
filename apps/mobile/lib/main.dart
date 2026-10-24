import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'auth/auth_gate.dart';
import 'auth/auth_service.dart';
import 'data/api_repository.dart';
import 'data/repository.dart';
import 'ui/briefing_data.dart';
import 'ui/common.dart';
import 'ui/components.dart';
import 'ui/home_screen.dart';
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
    runApp(GwittimApp(repository: SampleNoticeRepository(), openUrl: _openExternal, themeController: theme));
    return;
  }
  final baseUrl = Uri.parse(_apiBase.endsWith('/') ? _apiBase : '$_apiBase/');
  if (_devToken.isNotEmpty) {
    runApp(
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
  runApp(
    AuthGate(
      auth: FirebaseAuthService(),
      repositoryFor: (tokenProvider) => ApiNoticeRepository(baseUrl: baseUrl, tokenProvider: tokenProvider),
      openUrl: _openExternal,
      themeController: theme,
    ),
  );
}

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

class _HomeShellState extends State<HomeShell> {
  final _homeKey = GlobalKey<HomeScreenState>();
  final _savedKey = GlobalKey<SavedScreenState>();
  int _tab = 0;

  void _select(int i) {
    if (i == 1) _savedKey.currentState?.reload();
    setState(() => _tab = i);
  }

  @override
  Widget build(BuildContext context) {
    // 탭 화면에는 앱 바가 없어서 상태 표시줄 아이콘 색을 직접 맞춘다.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: statusBarStyle(Theme.of(context).brightness),
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: IndexedStack(
            index: _tab,
            children: [
              HomeScreen(
                key: _homeKey,
                repository: widget.repository,
                openUrl: widget.openUrl,
                briefingStore: widget.briefingStore,
                today: widget.today,
                onOpenProfile: () => _select(2),
              ),
              SavedScreen(key: _savedKey, repository: widget.repository, openUrl: widget.openUrl, today: widget.today),
              ProfileScreen(
                repository: widget.repository,
                themeController: widget.themeController,
                onSaved: () => _homeKey.currentState?.reload(),
                onSignOut: widget.onSignOut,
              ),
            ],
          ),
        ),
        bottomNavigationBar: GwTabBar(
          selected: _tab,
          onSelect: _select,
          tabs: const [
            (icon: Icons.home_outlined, activeIcon: Icons.home_rounded, label: '홈'),
            (icon: Icons.bookmark_border_rounded, activeIcon: Icons.bookmark_rounded, label: '저장'),
            (icon: Icons.person_outline_rounded, activeIcon: Icons.person_rounded, label: '프로필'),
          ],
        ),
      ),
    );
  }
}
