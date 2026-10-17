import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'data/repository.dart';
import 'ui/common.dart';
import 'ui/feed_screen.dart';

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
      home: FeedScreen(repository: repository, openUrl: openUrl, today: today),
    );
  }
}
