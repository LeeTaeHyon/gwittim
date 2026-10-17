import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'data/api_repository.dart';
import 'data/repository.dart';
import 'ui/common.dart';
import 'ui/feed_screen.dart';
import 'ui/profile_screen.dart';
import 'ui/saved_screen.dart';

// 실행 설정 (--dart-define):
//   GWITTIM_API_BASE  서버 API 주소. 비우면 합성 샘플 자료로 동작한다.
//   GWITTIM_DEV_TOKEN 로컬 개발 서버(backend.api.local)용 토큰. W6에서 Firebase Auth ID 토큰으로 바꾼다.
const _apiBase = String.fromEnvironment('GWITTIM_API_BASE');
const _devToken = String.fromEnvironment('GWITTIM_DEV_TOKEN');

void main() {
  final NoticeRepository repository = _apiBase.isEmpty
      ? SampleNoticeRepository()
      : ApiNoticeRepository(
          baseUrl: Uri.parse(_apiBase.endsWith('/') ? _apiBase : '$_apiBase/'),
          tokenProvider: () async => _devToken.isEmpty ? null : _devToken,
        );
  runApp(GwittimApp(repository: repository, openUrl: _openExternal));
}

Future<bool> _openExternal(Uri url) => launchUrl(url, mode: LaunchMode.externalApplication);

class GwittimApp extends StatelessWidget {
  const GwittimApp({super.key, required this.repository, required this.openUrl, this.today});

  final NoticeRepository repository;
  final OpenUrl openUrl;
  final DateTime? today;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '귀띔',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3D6BE0), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF3D6BE0), brightness: Brightness.dark, useMaterial3: true),
      home: HomeShell(repository: repository, openUrl: openUrl, today: today),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.repository, required this.openUrl, this.today});

  final NoticeRepository repository;
  final OpenUrl openUrl;
  final DateTime? today;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const _titles = ['귀띔', '저장한 공고', '내 프로필'];

  final _feedKey = GlobalKey<FeedScreenState>();
  final _savedKey = GlobalKey<SavedScreenState>();
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_titles[_tab])),
      body: IndexedStack(
        index: _tab,
        children: [
          FeedScreen(key: _feedKey, repository: widget.repository, openUrl: widget.openUrl, today: widget.today),
          SavedScreen(key: _savedKey, repository: widget.repository, openUrl: widget.openUrl, today: widget.today),
          ProfileScreen(repository: widget.repository, onSaved: () => _feedKey.currentState?.reload()),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          if (i == 1) _savedKey.currentState?.reload();
          setState(() => _tab = i);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.auto_awesome_outlined), label: '추천'),
          NavigationDestination(icon: Icon(Icons.bookmark_border), label: '저장'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: '프로필'),
        ],
      ),
    );
  }
}
