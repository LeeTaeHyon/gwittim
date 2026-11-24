import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/main.dart';
import 'package:gwittim/ui/briefing_data.dart';
import 'package:gwittim/ui/components.dart';
import 'package:gwittim/ui/report_screen.dart';

import 'package:gwittim/ui/theme.dart';

import 'app_test.dart' show OneNoticeRepository, notice;
import 'finders.dart';

/// 전역 글꼴 배율 상한. 기기 글자 크기를 최대로 키워도 앱은 [maxTextScale]배까지만 키운다.
void main() {
  final today = DateTime(2026, 10, 17);

  Future<void> pumpApp(WidgetTester tester, {BriefingStore? store}) async {
    final repo = SampleNoticeRepository(today: today);
    await tester.runAsync(repo.preload);
    await tester.pumpWidget(
      GwittimApp(
        repository: repo,
        openUrl: (_) async => true,
        today: today,
        briefingStore: store ?? MemoryBriefingStore(alwaysShown: true),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 360 폭 폰, 기기 글자 크기 2배
  void smallPhoneBigText(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 72, bottom: 72);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  for (final brightness in Brightness.values) {
    testWidgets('포스터 상세 확대·복귀, 큰 글자 $brightness', (tester) async {
      smallPhoneBigText(tester);
      final base = notice();
      const url = 'https://mjcms.mjc.ac.kr/crosseditor/binary/images/test.png';
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder);
      final picture = recorder.endRecording();
      final image = await tester.runAsync(() => picture.toImage(100, 350));
      picture.dispose();
      final cache = PaintingBinding.instance.imageCache;
      cache.putIfAbsent(
        const NetworkImage(url),
        () => OneFrameImageStreamCompleter(
          Future.value(ImageInfo(image: image!)),
        ),
      );
      addTearDown(() => cache.evict(const NetworkImage(url)));
      final repo = OneNoticeRepository(
        Notice(
          summary: base.summary,
          eligibility: base.eligibility,
          description: null,
          sourceId: 'mjc_www_notice',
          activityPeriod: null,
          applicationStart: null,
          lastVerifiedAt: null,
          posterUrl: url,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: gwittimTheme(brightness),
          builder: (context, child) => MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.3,
            child: child!,
          ),
          home: ReportScreen(
            repository: repo,
            noticeId: 'n',
            openUrl: (_) async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.bySemanticsLabel('포스터 크게 보기');
      await tester.ensureVisible(button);
      final position = tester.state<ScrollableState>(_vertical.first).position;
      final offset = position.pixels;
      for (final back in [false, true]) {
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<InteractiveViewer>(find.byType(InteractiveViewer))
              .maxScale,
          5,
        );
        final viewer = find.byType(InteractiveViewer);
        final transform = find.descendant(of: viewer, matching: find.byType(Transform)).first;
        final center = tester.getCenter(viewer);
        final left = await tester.startGesture(center - const Offset(30, 0), pointer: 1);
        final right = await tester.startGesture(center + const Offset(30, 0), pointer: 2);
        for (final distance in [55.0, 90.0]) {
          await left.moveTo(center - Offset(distance, 0));
          await right.moveTo(center + Offset(distance, 0));
          await tester.pump();
        }
        await left.up();
        await right.up();
        final zoom = tester.widget<Transform>(transform).transform.clone();
        expect(zoom.getMaxScaleOnAxis(), greaterThan(1));
        await tester.drag(viewer, const Offset(0, -65));
        await tester.pump();
        expect(tester.widget<Transform>(transform).transform, isNot(zoom));
        if (back) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byTooltip('닫기'));
        }
        await tester.pumpAndSettle();
        expect(position.pixels, offset);
        expect(button, findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('포스터를 기다리거나 디코딩에 실패해도 상세 행동을 유지한다', (tester) async {
    const url = 'https://mjcms.mjc.ac.kr/crosseditor/binary/images/invalid.png';
    final frame = Completer<ImageInfo>();
    final cache = PaintingBinding.instance.imageCache;
    cache.putIfAbsent(const NetworkImage(url), () => OneFrameImageStreamCompleter(frame.future));
    addTearDown(() => cache.evict(const NetworkImage(url)));
    final base = notice();
    final repo = OneNoticeRepository(Notice(
      summary: base.summary, eligibility: base.eligibility, description: null,
      activityPeriod: null, applicationStart: null, lastVerifiedAt: null, posterUrl: url,
    ));
    await tester.pumpWidget(MaterialApp(
      theme: gwittimTheme(),
      home: ReportScreen(repository: repo, noticeId: 'n', openUrl: (_) async => true),
    ));
    await tester.pump();
    expect(find.bySemanticsLabel('불러오는 중'), findsWidgets);
    expect(find.text('지원 전 체크리스트'), findsOneWidget);
    expect(find.text('포스터 크게 보기'), findsNothing);
    frame.completeError(StateError('decoding failed'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('불러오는 중'), findsNothing);
    expect(find.text('포스터 크게 보기'), findsNothing);
    expect(find.text('지원 전 체크리스트'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('기기 글자 크기 2배여도 앱 안에서는 1.3배', (tester) async {
    smallPhoneBigText(tester);
    await pumpApp(tester);
    expect(MediaQuery.textScalerOf(tester.element(find.byType(HomeShell))).scale(10), closeTo(13, 0.001));
  });

  testWidgets('기기 글자 크기가 1.3배보다 작으면 그대로 따른다', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.15;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpApp(tester);
    expect(MediaQuery.textScalerOf(tester.element(find.byType(HomeShell))).scale(10), closeTo(11.5, 0.001));
  });

  // 넘치면(RenderFlex overflow 등) 그 화면 이름과 함께 실패한다.
  testWidgets('360 폭·큰 글자: 브리핑, 네 탭, 내 정보·크레딧·프로필 고치기, 학교 밖 기회 찾기, 공고 리포트가 넘치지 않는다', (tester) async {
    smallPhoneBigText(tester);
    void noOverflow(String where) => expect(tester.takeException(), isNull, reason: where);

    await pumpApp(tester, store: MemoryBriefingStore()); // 하루 첫 실행이라 브리핑이 뜬다
    expect(find.byTooltip('브리핑 닫기'), findsOneWidget);
    await scrollToEnd(tester);
    noOverflow('브리핑');
    await tester.tap(find.byTooltip('브리핑 닫기'));
    await tester.pumpAndSettle();

    for (final tab in ['오늘', '공고', '달력', '저장함']) {
      await tester.tap(find.descendant(of: find.byType(GwTabBar), matching: find.text(tab)));
      await tester.pumpAndSettle();
      await scrollToEnd(tester);
      noOverflow('$tab 탭');
    }

    await tester.tap(find.descendant(of: find.byType(GwTabBar), matching: find.text('오늘')));
    await tester.pumpAndSettle();
    await scrollToEnd(tester, up: true); // 내 정보 버튼은 홈 머리에 있다
    await tester.tap(find.byTooltip('내 정보'));
    await tester.pumpAndSettle();
    await scrollToEnd(tester);
    noOverflow('내 정보');
    await tester.tap(find.text('크레딧'));
    await tester.pumpAndSettle();
    await scrollToEnd(tester);
    noOverflow('크레딧');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await scrollToEnd(tester, up: true);
    await tester.tap(find.text('고치기'));
    await tester.pumpAndSettle();
    for (final step in ['학적', '관심 분야', '희망 직무']) {
      await scrollToEnd(tester);
      noOverflow('프로필 고치기 $step');
      if (step != '희망 직무') {
        await tester.tap(find.text('다음'));
        await tester.pumpAndSettle();
      }
    }
    for (var i = 0; i < 4; i++) {
      await tester.binding.handlePopRoute(); // 단계마다 앞으로, 첫 단계에서 닫고, 내 정보도 닫는다
      await tester.pumpAndSettle();
    }

    // 학교 밖 기회 찾기 입구는 공고 탭 칩 줄 아래에 있다 (D-049)
    await tester.tap(find.descendant(of: find.byType(GwTabBar), matching: find.text('공고')));
    await tester.pumpAndSettle();
    await scrollToEnd(tester, up: true);
    await tester.tap(findTextContaining('학교 밖 기회 찾기').hitTestable());
    await tester.pumpAndSettle();
    await scrollToEnd(tester);
    noOverflow('학교 밖 기회 찾기');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(GwTabBar), matching: find.text('오늘')));
    await tester.pumpAndSettle();
    await scrollToEnd(tester, up: true);

    // 홈 마감 줄을 눌러 리포트를 연다 (D-050: 홈에는 공고 카드 대신 목록 줄)
    await tester.scrollUntilVisible(findText(_projectTitle), 300, scrollable: _vertical.hitTestable().first);
    await tester.tap(findText(_projectTitle).hitTestable());
    await tester.pumpAndSettle();
    expect(find.byType(ReportScreen), findsOneWidget);
    await scrollToEnd(tester);
    noOverflow('공고 리포트');
  });
}

const _projectTitle = '[합성 샘플] 컴퓨터공학과 프로젝트 발표회 참가자 모집';

final _vertical = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);

/// 보이는 화면의 세로 스크롤을 끝까지 내리며(up이면 맨 위까지 올리며) 그린다.
Future<void> scrollToEnd(WidgetTester tester, {bool up = false}) async {
  for (var i = 0; i < 40; i++) {
    final visible = _vertical.hitTestable();
    if (visible.evaluate().isEmpty) return;
    final position = tester.state<ScrollableState>(visible.first).position;
    if (up ? position.pixels <= position.minScrollExtent : position.pixels >= position.maxScrollExtent) return;
    await tester.drag(visible.first, Offset(0, up ? 400 : -400));
    await tester.pumpAndSettle();
  }
}
