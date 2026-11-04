import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'auth/auth_gate.dart';
import 'auth/auth_service.dart';
import 'data/api_repository.dart';
import 'data/cached_repository.dart';
import 'data/repository.dart';
import 'ui/app_info.dart';
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
  registerAppLicenses();
  // 화면 설정을 먼저 읽어서 첫 화면부터 고른 테마로 그린다 (D-010).
  final theme = await ThemeController.load(PrefsThemeStore());
  if (_apiBase.isEmpty) {
    _run(
      GwittimApp(
        repository: SampleNoticeRepository(today: DateTime.now()),
        openUrl: _openExternal,
        themeController: theme,
      ),
      source: '샘플 자료',
    );
    return;
  }
  final baseUrl = Uri.parse(_apiBase.endsWith('/') ? _apiBase : '$_apiBase/');
  if (_devToken.isNotEmpty) {
    _run(
      GwittimApp(
        repository: CachedNoticeRepository(ApiNoticeRepository(baseUrl: baseUrl, tokenProvider: ({refresh = false}) async => _devToken)),
        openUrl: _openExternal,
        themeController: theme,
      ),
      source: '로컬 서버',
    );
    return;
  }
  await Firebase.initializeApp();
  await FirebaseAuthService.initializeGoogle();
  _run(
    AuthGate(
      auth: FirebaseAuthService(),
      repositoryFor: (tokenProvider) =>
          CachedNoticeRepository(ApiNoticeRepository(baseUrl: baseUrl, tokenProvider: tokenProvider)),
      openUrl: _openExternal,
      themeController: theme,
    ),
  );
}

/// 시작 인트로를 씌워 실행한다 (D-011).
/// [source]가 있으면 dev 서버가 아닌 자료로 도는 실행이라 왼쪽 위에 띠로 표시한다.
void _run(Widget app, {String? source}) {
  final child = Intro(child: app);
  runApp(source == null ? child : DataSourceBanner(label: source, child: child));
}

/// 합성 샘플·로컬 서버로 도는 실행을 dev 서버 실행과 헷갈리지 않게 왼쪽 위 모서리에 띠를 붙인다.
/// DEBUG 띠(오른쪽 위)와 겹치지 않고, 서버 주소를 넣은 빌드에는 붙지 않는다.
class DataSourceBanner extends StatelessWidget {
  const DataSourceBanner({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Banner(
      message: label,
      location: BannerLocation.topStart,
      textDirection: TextDirection.ltr,
      layoutDirection: TextDirection.ltr,
      color: const Color(0xE03446A8),
      child: child,
    );
  }
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
    this.onDeleteAccount,
    this.briefingStore,
    this.themeController,
  });

  final NoticeRepository repository;
  final OpenUrl openUrl;
  final DateTime? today;

  /// 로그인 모드일 때만 있다.
  final Future<void> Function()? onSignOut;

  /// 탈퇴 (D-024). 로그인 모드일 때만 있다. 계정 확인을 취소하면 false.
  final Future<bool> Function()? onDeleteAccount;

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
        onDeleteAccount: widget.onDeleteAccount,
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
    this.onDeleteAccount,
    this.clock = DateTime.now,
  });

  final Future<void> Function()? onSignOut;
  final Future<bool> Function()? onDeleteAccount;
  final NoticeRepository repository;
  final OpenUrl openUrl;
  final BriefingStore briefingStore;
  final ThemeController themeController;
  final DateTime? today;

  /// 앱이 다시 앞으로 나왔을 때 새로 받을지 정하는 시계. 테스트용.
  final DateTime Function() clock;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

/// 뒤로 갔던 앱이 이만큼 지나 돌아오면 탭을 새로 받는다. 수집 배치가 하루 두 번이라 잠깐 다녀온 경우는 그대로 둔다.
const resumeRefreshAfter = Duration(minutes: 30);

class _HomeShellState extends State<HomeShell> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _homeKey = GlobalKey<HomeScreenState>();
  final _noticesKey = GlobalKey<NoticesScreenState>();
  final _calendarKey = GlobalKey<CalendarScreenState>();
  final _savedKey = GlobalKey<SavedScreenState>();
  int _tab = 0;

  /// 앱이 뒤로 간 시각. 돌아올 때 날짜가 바뀌었으면 D-day·달력 '오늘'이 어제에 머물지 않게 다시 받는다.
  DateTime? _leftAt;

  /// 화면을 켜 둔 채 자정을 넘길 때 탭을 새로 받는 타이머. 앱이 뒤로 가면 멈추고, 돌아오면 그때 시계로 다시 잡는다.
  Timer? _midnight;

  /// 탭을 바꾼 방향 (오른쪽 탭으로 가면 1)
  int _direction = 1;

  /// 탭을 바꾸면 지금 화면은 바로 감추고, 새 화면만 고른 쪽에서 밀려 들어온다.
  /// 두 화면을 겹쳐 흐리게 하면 GPU 그리기가 프레임당 30~50ms까지 늘어 끊긴다(S25 Ultra 측정).
  late final _switch = AnimationController(vsync: this, duration: const Duration(milliseconds: 320), value: 1);

  void _select(int i) {
    // 저장 상태가 다른 탭에서 바뀔 수 있어 다시 받는다.
    if (i == 2) _calendarKey.currentState?.reload();
    if (i == 3) _savedKey.currentState?.reload();
    if (i == _tab) return;
    final animate = MediaQuery.maybeDisableAnimationsOf(context) != true;
    setState(() {
      _direction = i > _tab ? 1 : -1;
      _tab = i;
    });
    if (animate) _switch.forward(from: 0);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleMidnight();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _midnight?.cancel();
    _switch.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final now = widget.clock();
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      _leftAt ??= now;
      _midnight?.cancel();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    _scheduleMidnight();
    final left = _leftAt;
    _leftAt = null;
    if (left == null) return;
    final newDay = DateUtils.dateOnly(left) != DateUtils.dateOnly(now);
    if (newDay || now.difference(left) >= resumeRefreshAfter) _refreshTabs();
  }

  /// 다음 자정에 탭을 새로 받는다. 타이머가 조금 일찍 깨도 새 날짜로 계산되게 1초 뒤로 잡는다.
  void _scheduleMidnight() {
    _midnight?.cancel();
    final now = widget.clock();
    final next = DateTime(now.year, now.month, now.day + 1);
    _midnight = Timer(next.difference(now) + const Duration(seconds: 1), () {
      _refreshTabs();
      _scheduleMidnight();
    });
  }

  /// 탭끼리 나눠 쓰는 응답을 버리고 네 탭을 다시 받는다. 받는 동안 보이던 화면은 그대로 둔다.
  void _refreshTabs() {
    forgetCached(widget.repository);
    _homeKey.currentState?.reload();
    _noticesKey.currentState?.reload();
    _calendarKey.currentState?.reload();
    _savedKey.currentState?.reload();
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
          onDeleteAccount: widget.onDeleteAccount == null ? null : _deleteAccount,
        ),
      ),
    );
  }

  /// 탈퇴하면 기기에 남은 학과 통계 추천 답(D-021)도 지운다.
  Future<bool> _deleteAccount() async {
    final store = widget.briefingStore;
    final done = await widget.onDeleteAccount!();
    if (done) {
      try {
        await store.saveMajorPicks(const MajorPickState());
      } catch (_) {
        // 기기 저장소를 못 쓰면 남는다. 서버 데이터·계정 삭제는 이미 끝났다.
      }
    }
    return done;
  }

  /// 첫 로그인 등으로 프로필이 없으면 홈이 한 번 부른다. 홈은 끝난 뒤 스스로 다시 받는다.
  Future<void> _setupProfile() async {
    final saved = await openProfileSetup(context, widget.repository);
    if (saved == null || !mounted) return;
    _noticesKey.currentState?.reload();
    _calendarKey.currentState?.reload();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('프로필이 저장되었습니다.')));
  }

  /// 탭 화면 하나. 위젯 구조는 늘 같게 두어 화면 상태가 유지된다.
  Widget _page(int i, Widget screen) {
    return Offstage(
      offstage: i != _tab,
      child: AnimatedBuilder(
        animation: _switch,
        child: screen,
        builder: (context, child) {
          final t = Curves.easeOutCubic.transform(_switch.value);
          final dx = i == _tab ? _direction * 48 * (1 - t) : 0.0;
          return Transform.translate(offset: Offset(dx, 0), child: child);
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
                  // 샘플·개발 토큰 모드에서는 자동으로 띄우지 않는다.
                  onSetupProfile: widget.onSignOut == null ? null : _setupProfile,
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
