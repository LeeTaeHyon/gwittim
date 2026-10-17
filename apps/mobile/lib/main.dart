import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'data/repository.dart';
import 'ui/common.dart';
import 'ui/feed_screen.dart';
import 'ui/profile_screen.dart';
import 'ui/saved_screen.dart';

void main() {
  // W6에서 Firebase 로그인과 실제 Repository로 교체한다. 지금은 합성 샘플 자료를 쓴다.
  runApp(GwittimApp(repository: SampleNoticeRepository(), openUrl: _openExternal));
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
