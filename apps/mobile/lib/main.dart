import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'auth/auth_gate.dart';
import 'auth/auth_service.dart';
import 'data/api_repository.dart';
import 'data/repository.dart';
import 'ui/briefing_data.dart';
import 'ui/common.dart';
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
  if (_apiBase.isEmpty) {
    runApp(GwittimApp(repository: SampleNoticeRepository(), openUrl: _openExternal));
    return;
  }
  final baseUrl = Uri.parse(_apiBase.endsWith('/') ? _apiBase : '$_apiBase/');
  if (_devToken.isNotEmpty) {
    runApp(
      GwittimApp(
        repository: ApiNoticeRepository(baseUrl: baseUrl, tokenProvider: () async => _devToken),
        openUrl: _openExternal,
      ),
    );
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await FirebaseAuthService.initializeGoogle();
  runApp(
    AuthGate(
      auth: FirebaseAuthService(),
      repositoryFor: (tokenProvider) => ApiNoticeRepository(baseUrl: baseUrl, tokenProvider: tokenProvider),
      openUrl: _openExternal,
    ),
  );
}

Future<bool> _openExternal(Uri url) => launchUrl(url, mode: LaunchMode.externalApplication);

class GwittimApp extends StatelessWidget {
  const GwittimApp({
    super.key,
    required this.repository,
    required this.openUrl,
    this.today,
    this.onSignOut,
    this.briefingStore,
  });

  final NoticeRepository repository;
  final OpenUrl openUrl;
  final DateTime? today;

  /// 로그인 모드일 때만 있다.
  final Future<void> Function()? onSignOut;

  /// 하루 첫 실행 기록. 기본은 기기 저장소 (D-009).
  final BriefingStore? briefingStore;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '귀띔',
      theme: gwittimTheme(),
      home: HomeShell(
        repository: repository,
        openUrl: openUrl,
        today: today,
        onSignOut: onSignOut,
        briefingStore: briefingStore ?? PrefsBriefingStore(),
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
    this.today,
    this.onSignOut,
  });

  final Future<void> Function()? onSignOut;
  final NoticeRepository repository;
  final OpenUrl openUrl;
  final BriefingStore briefingStore;
  final DateTime? today;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const _titles = ['', '저장한 공고', '내 프로필'];

  final _homeKey = GlobalKey<HomeScreenState>();
  final _savedKey = GlobalKey<SavedScreenState>();
  int _tab = 0;

  void _select(int i) {
    if (i == 1) _savedKey.currentState?.reload();
    setState(() => _tab = i);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _tab == 0
          ? null
          : AppBar(
              title: Text(_titles[_tab]),
              actions: [
                if (_tab == 2 && widget.onSignOut != null)
                  IconButton(tooltip: '로그아웃', icon: const Icon(Icons.logout), onPressed: widget.onSignOut),
              ],
            ),
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
            ProfileScreen(repository: widget.repository, onSaved: () => _homeKey.currentState?.reload()),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _select,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: '홈'),
          NavigationDestination(icon: Icon(Icons.bookmark_border), selectedIcon: Icon(Icons.bookmark), label: '저장'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: '프로필'),
        ],
      ),
    );
  }
}
