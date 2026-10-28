import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/main.dart';
import 'package:gwittim/ui/briefing_data.dart';
import 'package:gwittim/ui/briefing_screen.dart';
import 'package:gwittim/ui/common.dart';
import 'package:gwittim/ui/components.dart';
import 'package:gwittim/ui/logo.dart';
import 'package:gwittim/ui/notices_screen.dart';
import 'package:gwittim/ui/report_screen.dart';
import 'package:gwittim/ui/skeleton.dart';
import 'package:gwittim/ui/theme.dart';

/// 목록 응답을 직접 풀어 줄 때까지 기다리게 한다.
class SlowRepository extends SampleNoticeRepository {
  final gate = Completer<void>();

  @override
  Future<RecommendationList> listRecommendations() async {
    await gate.future;
    return super.listRecommendations();
  }
}

void main() {
  final today = DateTime(2026, 10, 17);

  Future<SampleNoticeRepository> pumpApp(WidgetTester tester, {BriefingStore? briefing}) async {
    final repo = SampleNoticeRepository();
    await tester.runAsync(repo.preload);
    await tester.pumpWidget(
      GwittimApp(
        repository: repo,
        openUrl: (_) async => true,
        today: today,
        briefingStore: briefing ?? MemoryBriefingStore(alwaysShown: true),
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  void reduceMotion(WidgetTester tester) {
    tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }

  group('오류·빈 화면', () {
    testWidgets('말풍선 그림, 한 줄 제목과 설명, 앱 버튼의 다시 시도', (tester) async {
      var retried = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: gwittimTheme(),
          home: Scaffold(
            body: MessageView.error(
              const RepositoryException(RepositoryErrorKind.unavailable),
              onRetry: () => retried++,
            ),
          ),
        ),
      );
      expect(find.byType(GwBubbleMark), findsOneWidget);
      expect(find.text('불러오지 못했어요'), findsOneWidget);
      expect(find.text('잠시 후 다시 시도해 주세요.'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(Icon), findsNothing); // 구름 아이콘 없음
      await tester.tap(find.widgetWithText(SoftButton, '다시 시도'));
      expect(retried, 1);
    });
  });

  group('로딩 자리표시', () {
    testWidgets('목록을 받는 동안 화면 모양의 회색 면을 보이고, 화면 읽기에는 불러오는 중', (tester) async {
      final repo = SlowRepository();
      await tester.runAsync(repo.preload);
      await tester.pumpWidget(
        GwittimApp(
          repository: repo,
          openUrl: (_) async => true,
          today: today,
          briefingStore: MemoryBriefingStore(alwaysShown: true),
        ),
      );
      await tester.pump();
      expect(find.byType(HomeSkeleton), findsOneWidget);
      expect(find.bySemanticsLabel('불러오는 중'), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // 밝기가 은은하게 바뀐다
      double opacity() => tester
          .widget<FadeTransition>(
            find.descendant(of: find.byType(HomeSkeleton), matching: find.byType(FadeTransition)).first,
          )
          .opacity
          .value;
      final first = opacity();
      await tester.pump(const Duration(milliseconds: 400));
      expect(opacity(), isNot(first));

      repo.gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(HomeSkeleton), findsNothing);
      expect(find.text('다가오는 마감'), findsOneWidget);
    });

    testWidgets('애니메이션 줄이기 설정이면 깜빡이지 않는다', (tester) async {
      reduceMotion(tester);
      final repo = SlowRepository();
      await tester.runAsync(repo.preload);
      await tester.pumpWidget(
        GwittimApp(
          repository: repo,
          openUrl: (_) async => true,
          today: today,
          briefingStore: MemoryBriefingStore(alwaysShown: true),
        ),
      );
      await tester.pump();
      expect(find.byType(HomeSkeleton), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
      repo.gate.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('로그인 대기의 로고 점', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: gwittimTheme(),
          home: const Scaffold(body: Center(child: GwLoadingLogo())),
        ),
      );
      expect(find.bySemanticsLabel('불러오는 중'), findsOneWidget);
      expect(tester.getSize(find.byType(GwBubbleMark)).height, 56); // 로그인 화면 로고 크기
      expect(tester.hasRunningAnimations, isTrue);
    });
  });

  group('화면 이동과 위 막대', () {
    testWidgets('공고 리포트는 오른쪽에서 밀려 들어오고, 뒤로 가면 오른쪽으로 나간다', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('공고'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(NoticeCard).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getTopLeft(find.byType(ReportScreen)).dx, greaterThan(0));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byType(ReportScreen)).dx, 0);

      await tester.tap(find.byTooltip('뒤로'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      expect(tester.getTopLeft(find.byType(ReportScreen)).dx, greaterThan(0));
      await tester.pumpAndSettle();
      expect(find.byType(ReportScreen), findsNothing);
    });

    testWidgets('하루 첫 브리핑은 아래에서 올라온다', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('브리핑 자세히 보기'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getTopLeft(find.byType(BriefingScreen)).dy, greaterThan(0));
      expect(tester.getTopLeft(find.byType(BriefingScreen)).dx, 0);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byType(BriefingScreen)).dy, 0);
    });

    testWidgets('애니메이션 줄이기 설정이면 바로 바뀐다', (tester) async {
      reduceMotion(tester);
      await pumpApp(tester);
      await tester.tap(find.text('공고'));
      await tester.pump();
      await tester.tap(find.byType(NoticeCard).first);
      await tester.pump();
      await tester.pump();
      expect(tester.getTopLeft(find.byType(ReportScreen)).dx, 0);
    });

    testWidgets('리포트 위 막대: 스크롤하면 card 바탕·구분선과 공고 제목이 나타난다', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('공고'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(NoticeCard).first);
      await tester.pumpAndSettle();

      final bar = find.byType(GwTopBar);
      BoxDecoration decoration() =>
          tester
                  .widget<AnimatedContainer>(find.descendant(of: bar, matching: find.byType(AnimatedContainer)))
                  .decoration!
              as BoxDecoration;
      double titleOpacity() =>
          tester.widget<AnimatedOpacity>(find.descendant(of: bar, matching: find.byType(AnimatedOpacity))).opacity;
      expect(titleOpacity(), 0);
      expect((decoration().border! as Border).bottom.color.a, 0);

      await tester.drag(find.text('지원 전 체크리스트'), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(titleOpacity(), 1);
      expect((decoration().border! as Border).bottom.color, GwColors.light.line);
      expect(decoration().color, GwColors.light.card);
      final title = tester.widget<Text>(find.descendant(of: bar, matching: find.byType(Text)));
      expect(title.maxLines, 1);
      expect(title.data, contains('[합성 샘플]'));
    });
  });

  group('브리핑', () {
    testWidgets('카드 좌우 여백이 같고, 마지막 문구는 아래 버튼에 가리지 않는다', (tester) async {
      await pumpApp(tester, briefing: MemoryBriefingStore());
      expect(find.byType(BriefingScreen), findsOneWidget);
      expect(find.byTooltip('브리핑 닫기'), findsOneWidget);

      final screen = tester.getRect(find.byType(BriefingScreen));
      final card = tester.getRect(find.byType(GwCard).first);
      expect(card.left - screen.left, moreOrLessEquals(screen.right - card.right));

      final list = find.descendant(of: find.byType(BriefingScreen), matching: find.byType(Scrollable)).first;
      await tester.fling(list, const Offset(0, -3000), 3000);
      await tester.pumpAndSettle();
      final caption = find.textContaining('합격 가능성을 뜻하지 않아요');
      final button = find.widgetWithText(FilledButton, '확인했어요');
      expect(tester.getBottomLeft(caption).dy, lessThanOrEqualTo(tester.getTopLeft(button).dy - 24));

      await tester.tap(find.byTooltip('브리핑 닫기'));
      await tester.pumpAndSettle();
      expect(find.byType(BriefingScreen), findsNothing);
    });
  });
}
