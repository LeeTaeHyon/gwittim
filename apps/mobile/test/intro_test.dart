import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/ui/intro.dart';
import 'package:gwittim/ui/logo.dart';

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
  testWidgets('말풍선에 글자를 채운 뒤 사라지고, 뒤의 앱은 그대로', (tester) async {
    final inits = <int>[];
    await tester.pumpWidget(Intro(child: MaterialApp(home: _Probe(inits))));

    final logo = find.byType(GwLogo);
    expect(logo, findsOneWidget);
    expect(tester.getSize(logo), const Size(150, 93.75));
    expect(tester.getCenter(logo), tester.getCenter(find.byType(Intro)));
    expect(find.text('앱 본체'), findsOneWidget); // 앱은 뒤에서 먼저 뜬다

    await tester.pump(Intro.duration ~/ 2);
    expect(logo, findsOneWidget);

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

  test('Android 시작 화면의 말풍선과 같은 모양·크기·자리', () {
    final xml = File('android/app/src/main/res/drawable/splash_bubble.xml').readAsStringSync();
    double attr(String name) => double.parse(RegExp('android:$name="([\\d.]+)"').firstMatch(xml)![1]!);
    expect(xml, contains('android:pathData="$logoBubbleData"'));
    const width = Intro.logoHeight * 400 / 250;
    expect(attr('viewportWidth'), 288);
    expect(attr('scaleX') * 400, width);
    expect(attr('translateX'), (288 - width) / 2);
    expect(attr('translateY'), (288 - Intro.logoHeight) / 2);
  });
}
