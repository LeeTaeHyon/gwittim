import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/ui/intro.dart';
import 'package:gwittim/ui/logo.dart';
import 'package:gwittim/ui/theme.dart';

/// 처음 만들어진 횟수를 센다 (인트로가 끝나도 앱 상태가 그대로인지).
class _Probe extends StatefulWidget {
  const _Probe(this.inits);

  final List<int> inits;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.inits.add(1);
  }

  @override
  Widget build(BuildContext context) => const Text('앱 본체');
}

void main() {
  testWidgets('말풍선이 등장해 글자를 채운 뒤 사라지고, 뒤의 앱은 그대로', (tester) async {
    final inits = <int>[];
    await tester.pumpWidget(Intro(child: MaterialApp(home: _Probe(inits))));

    final logo = find.byType(GwLogo);
    double opacity() => tester
        .widget<FadeTransition>(find.ancestor(of: logo, matching: find.byType(FadeTransition)).first)
        .opacity
        .value;
    double scale() =>
        tester.widget<ScaleTransition>(find.ancestor(of: logo, matching: find.byType(ScaleTransition))).scale.value;
    expect(opacity(), 0); // 시작 화면처럼 바탕만 보인다
    expect(scale(), lessThan(1));
    expect(find.text('앱 본체'), findsOneWidget); // 앱은 뒤에서 먼저 뜬다

    await tester.pump(Intro.duration ~/ 2);
    expect(opacity(), 1);
    expect(scale(), 1);
    expect(tester.getSize(logo), const Size(150, 93.75));
    expect(tester.getCenter(logo), tester.getCenter(find.byType(Intro)));

    await tester.pumpAndSettle();
    expect(logo, findsNothing);
    expect(find.text('앱 본체'), findsOneWidget);
    expect(inits, hasLength(1));
  });

  testWidgets('애니메이션 줄이기 설정이면 인트로 없이 바로 앱', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(Intro(child: MaterialApp(home: _Probe([]))));
    expect(find.byType(GwLogo), findsNothing);
    expect(find.text('앱 본체'), findsOneWidget);
  });

  test('Android 시작 화면은 인트로와 같은 네이비 바탕만 (말풍선은 인트로에서 등장)', () {
    const res = 'android/app/src/main/res';
    expect(File('$res/values/ic_launcher_background.xml').readAsStringSync(), contains('#22306B'));
    expect(GwColors.light.loginBg, const Color(0xFF22306B));
    for (final dir in ['values', 'values-night']) {
      final styles = File('$res/$dir/styles.xml').readAsStringSync();
      expect(styles, contains('windowSplashScreenBackground" tools:targetApi="31">@color/ic_launcher_background<'));
      expect(styles, contains('windowSplashScreenAnimatedIcon" tools:targetApi="31">@android:color/transparent<'));
    }
    for (final dir in ['drawable', 'drawable-v21']) {
      final layers = File('$res/$dir/launch_background.xml').readAsStringSync();
      expect(RegExp('<item ').allMatches(layers), hasLength(1));
      expect(layers, contains('<item android:drawable="@color/ic_launcher_background" />'));
    }
  });
}
