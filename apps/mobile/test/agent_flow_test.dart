import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/ui/agent_data.dart';
import 'package:gwittim/ui/components.dart';
import 'package:gwittim/ui/credits_screen.dart';
import 'package:gwittim/ui/profile_screen.dart';
import 'package:gwittim/ui/report_screen.dart';
import 'package:gwittim/ui/theme.dart';

import 'finders.dart';

const _id = 'n_synthetic_0001';
const _title = '[합성 샘플] 2026학년도 아이디어 경진대회 참가 안내';

/// 보낸 칩을 기록하고, 원하면 오류를 낸다.
class _Repo extends SampleNoticeRepository {
  _Repo({super.analysisDelay}) : super(personalized: true);

  AnalysisChips? sentChips;
  final sentIds = <String>[];
  RepositoryErrorKind? failWith;

  @override
  Future<AnalysisResponse> requestAnalysis({
    required String noticeId,
    required String requestId,
    AnalysisChips chips = const AnalysisChips(),
  }) {
    sentChips = chips;
    sentIds.add(requestId);
    if (failWith case final kind?) {
      return Future.error(RepositoryException(kind, fromServer: true));
    }
    return super.requestAnalysis(noticeId: noticeId, requestId: requestId, chips: chips);
  }
}

Future<T> _open<T extends SampleNoticeRepository>(
  WidgetTester tester,
  T repo, {
  bool consent = false,
  Widget Function(T repo)? screen,
}) async {
  // 목록 아래쪽까지 한 번에 만들어지도록 화면을 길게 둔다.
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(repo.preload);
  if (consent) await repo.grantAgentConsent();
  await tester.pumpWidget(
    MaterialApp(
      theme: gwittimTheme(),
      home:
          screen?.call(repo) ??
          ReportScreen(
            repository: repo,
            noticeId: _id,
            openUrl: (_) async => true,
            today: DateTime(2026, 10, 17),
            agentStore: MemoryAgentChipStore(),
          ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

/// 목록 아래쪽은 아직 만들어지지 않았을 수 있어 먼저 내려가 본다.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// 크레딧 줄이 보이면 그 값이 곧 잔액이다.
Future<int> _balance(SampleNoticeRepository repo) async => (await repo.getCredits()).balance;

void main() {
  group('상세 분석 버튼', () {
    testWidgets('처음이면 동의 화면부터, 동의하지 않으면 차감 없이 돌아온다', (tester) async {
      final repo = await _open(tester, _Repo());
      await _tap(tester, findText('내 기준으로 자세히 보기'));
      expect(findText('AI에 보내는 정보'), findsOneWidget);
      expect(findText('이름·이메일·학번 등 직접 식별 정보는 보내지 않습니다.'), findsOneWidget);
      await _reveal(tester, find.text('동의하지 않음'));
      expect(findText('DeepSeek(중국)'), findsOneWidget);
      expect(findTextContaining('모델 학습에 쓰일 수 있습니다'), findsOneWidget);
      // 두 버튼은 같은 크기
      expect(
        tester.getSize(find.widgetWithText(FilledButton, '동의하고 계속')),
        tester.getSize(find.widgetWithText(FilledButton, '동의하지 않음')),
      );
      await _tap(tester, find.text('동의하지 않음'));
      await tester.pumpAndSettle();
      expect(findText('내 기준으로 자세히 보기'), findsOneWidget);
      expect((await repo.getProfile()).hasAgentConsent, isFalse);
      expect(await _balance(repo), 5);
    });

    testWidgets('동의하면 프로필에 동의 기록이 남고 질문 화면으로 간다. 나가면 차감 없음', (tester) async {
      final repo = await _open(tester, _Repo());
      await _tap(tester, findText('내 기준으로 자세히 보기'));
      await _tap(tester, find.text('동의하고 계속'));
      await tester.pumpAndSettle();
      expect((await repo.getProfile()).hasAgentConsent, isTrue);
      // 질문 제목과 안내는 한 문단이라 큰 글자에서 안내가 통째로 아랫줄로 간다.
      expect(findText('해 본 것  여러 개 선택'), findsOneWidget);
      expect(findText('가능한 시기  하나 선택'), findsOneWidget);
      expect(findText('갈 수 있는 지역  여러 개 선택'), findsOneWidget);
      await tester.tap(find.byTooltip('뒤로'));
      await tester.pumpAndSettle();
      expect(await _balance(repo), 5);
      expect(repo.sentIds, isEmpty);
    });

    testWidgets('크레딧 0이면 버튼이 비활성이고 안내와 크레딧 링크가 보인다', (tester) async {
      final repo = _Repo()..debugSetBalance(0);
      await _open(tester, repo, consent: true);
      await _reveal(tester, find.text('크레딧 보기'));
      final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '내 기준으로 자세히 보기'));
      expect(button.onPressed, isNull);
      expect(findText('크레딧 없음 · 내일 0시 1개 충전'), findsOneWidget);
      expect(find.text('크레딧 보기'), findsOneWidget);
    });

    testWidgets('크레딧 있음: 비용 1과 남은 개수', (tester) async {
      await _open(tester, _Repo(), consent: true);
      await _reveal(tester, find.text('남은 5개'));
      expect(find.text('1크레딧 ·'), findsOneWidget);
      expect(find.text('남은 5개'), findsOneWidget);
    });
  });

  group('질문 화면', () {
    Future<_Repo> toQuestions(WidgetTester tester) async {
      final repo = await _open(tester, _Repo(), consent: true);
      await _tap(tester, findText('내 기준으로 자세히 보기'));
      return repo;
    }

    testWidgets('아직 없음·상관없음은 단독 칩, 시기는 하나만', (tester) async {
      final repo = await toQuestions(tester);
      await _tap(tester, find.text('파이썬'));
      await _tap(tester, find.text('자바'));
      await _tap(tester, find.text('아직 없음')); // 다른 칩이 꺼진다
      await _tap(tester, find.text('서울'));
      await _tap(tester, find.text('온라인만'));
      await _tap(tester, find.text('상관없음').last); // 지역의 상관없음: 서울·온라인만이 꺼진다
      await _tap(tester, find.text('학기 중'));
      await _tap(tester, find.text('방학')); // 하나만
      await _tap(tester, find.text('분석하기'));
      expect(repo.sentChips!.experience, ['none_yet']);
      expect(repo.sentChips!.regions, ['any']);
      expect(repo.sentChips!.period, 'vacation');
    });

    testWidgets('칩은 높이 36으로 보이고, 위아래 여백까지 누르는 영역이다', (tester) async {
      final repo = await toQuestions(tester);
      final chip = find.ancestor(of: find.text('파이썬'), matching: find.byType(AnswerChip));
      final face = find.descendant(of: chip, matching: find.byType(Material));
      expect(tester.getSize(face).height, 36);
      expect(tester.getSize(chip).height, 44);
      // 칩 면 바로 위 여백(2만큼 위)을 눌러도 고른다
      await tester.tapAt(tester.getRect(face).topCenter - const Offset(0, 2));
      await tester.pumpAndSettle();
      await _tap(tester, find.text('분석하기'));
      expect(repo.sentChips!.experience, ['python']);
    });

    testWidgets('단독 칩을 고른 뒤 다른 칩을 누르면 단독 칩이 꺼진다', (tester) async {
      final repo = await toQuestions(tester);
      await _tap(tester, find.text('아직 없음'));
      await _tap(tester, find.text('파이썬'));
      await _tap(tester, find.text('분석하기'));
      expect(repo.sentChips!.experience, ['python']);
    });

    testWidgets('건너뛰고 분석은 빈 칩, 리포트 맨 위에 안내', (tester) async {
      final repo = await toQuestions(tester);
      await _tap(tester, find.text('건너뛰고 분석'));
      expect(repo.sentChips!.isEmpty, isTrue);
      expect(findText('해 본 것 정보가 없어 공고의 요구 사항만 정리했습니다.'), findsOneWidget);
    });

    testWidgets('다음에도 이대로를 켜면 기기에 저장되고, 다음에 그대로 채워진다', (tester) async {
      final store = MemoryAgentChipStore();
      final repo = _Repo();
      await _open(
        tester,
        repo,
        consent: true,
        screen: (r) => ReportScreen(repository: r, noticeId: _id, openUrl: (_) async => true, agentStore: store),
      );
      await _tap(tester, findText('내 기준으로 자세히 보기'));
      await _tap(tester, find.text('웹 화면'));
      await _tap(tester, find.text('다음에도 이대로'));
      await _tap(tester, find.text('분석하기'));
      expect((await store.read())!.experience, ['web_ui']);
      // 결과 화면을 닫고 다시 열면 저장한 칩이 켜져 있다
      await tester.tap(find.byTooltip('뒤로'));
      await tester.pumpAndSettle();
      await _tap(tester, findText('받은 분석 보기'));
      expect(findText('나와 이 공고'), findsOneWidget);
    });
  });

  group('리포트와 기다리는 화면', () {
    testWidgets('리포트 4칸은 맞는 점 → 지원 자격 → 할 일 → 역량 순서', (tester) async {
      await _open(tester, _Repo(), consent: true);
      await _tap(tester, findText('내 기준으로 자세히 보기'));
      await _tap(tester, find.text('건너뛰고 분석'));
      double top(String t) => tester.getTopLeft(findText(t)).dy;
      expect(top('나와 이 공고'), lessThan(top('지원 자격')));
      expect(top('지원 자격'), lessThan(top('지원 전 할 일')));
      await tester.scrollUntilVisible(findText('필요한 역량'), 200, scrollable: find.byType(Scrollable).first);
      expect(top('지원 전 할 일'), lessThan(top('필요한 역량')));
      await _reveal(tester, findTextContaining('합격 가능성과는 관계없습니다'));
      expect(findText('AI가 공고와 내 정보로 정리한 내용입니다. 합격 가능성과는 관계없습니다.'), findsOneWidget);
    });

    testWidgets('성공하면 크레딧 1개가 줄고 버튼이 받은 분석 보기로 바뀐다', (tester) async {
      final repo = await _open(tester, _Repo(), consent: true);
      await _tap(tester, findText('내 기준으로 자세히 보기'));
      await _tap(tester, find.text('건너뛰고 분석'));
      await tester.tap(find.byTooltip('뒤로'));
      await tester.pumpAndSettle();
      expect(await _balance(repo), 4);
      expect(findText('받은 분석 보기'), findsOneWidget);
      expect(findTextContaining('무료 · '), findsOneWidget); // 받은 시각 캡션
      // 받은 분석 다시 보기는 무료
      await _tap(tester, findText('받은 분석 보기'));
      expect(findTextContaining('받은 분석 · '), findsOneWidget);
      expect(await _balance(repo), 4);
    });

    testWidgets('기다리는 동안 단계·나가도 된다는 안내가 보인다 (애니메이션 줄이기: 마지막 단계)', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await _open(tester, _Repo(analysisDelay: const Duration(seconds: 2)), consent: true);
      await _tap(tester, findText('내 기준으로 자세히 보기'));
      await tester.tap(find.text('건너뛰고 분석'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(findText('공고 읽는 중'), findsOneWidget);
      expect(findText('내 정보와 비교 중'), findsOneWidget);
      expect(findText('정리 중'), findsOneWidget);
      expect(findText('화면을 나가도 분석은 계속됩니다. 끝나면 이 공고에서 볼 수 있습니다.'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(2)); // 앞 두 단계는 끝난 모양으로 고정
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(findText('나와 이 공고'), findsOneWidget);
    });

    testWidgets('AI 실패: 차감되지 않았다는 안내, 다시 시도는 같은 요청 id', (tester) async {
      final repo = _Repo()..failWith = RepositoryErrorKind.unavailable;
      await _open(tester, repo, consent: true);
      await _tap(tester, findText('내 기준으로 자세히 보기'));
      await _tap(tester, find.text('건너뛰고 분석'));
      expect(findText('분석 실패'), findsOneWidget);
      expect(findTextContaining('크레딧은 차감되지 않았습니다'), findsOneWidget);
      expect(await _balance(repo), 5);
      repo.failWith = null;
      await _tap(tester, find.text('다시 시도'));
      expect(findText('나와 이 공고'), findsOneWidget);
      expect(repo.sentIds.toSet().length, 1); // 재시도 때만 같은 값
      expect(await _balance(repo), 4);
    });

    testWidgets('오류별 안내: 크레딧 부족·진행 중·동의 없음', (tester) async {
      final repo = _Repo()..failWith = RepositoryErrorKind.insufficientCredits;
      await _open(tester, repo, consent: true);
      await _tap(tester, findText('내 기준으로 자세히 보기'));
      await _tap(tester, find.text('건너뛰고 분석'));
      expect(findText('크레딧 부족'), findsOneWidget);
      expect(find.text('크레딧 보기'), findsOneWidget);

      await tester.tap(find.byTooltip('뒤로'));
      await tester.pumpAndSettle();
      repo.failWith = RepositoryErrorKind.requestInProgress;
      await _tap(tester, findText('내 기준으로 자세히 보기'));
      await _tap(tester, find.text('건너뛰고 분석'));
      expect(findText('분석 진행 중'), findsOneWidget);
      expect(find.text('다시 시도'), findsOneWidget);

      repo.failWith = RepositoryErrorKind.consentRequired;
      await _tap(tester, find.text('다시 시도'));
      expect(findText('AI 전송 동의 필요'), findsOneWidget);
      await _tap(tester, find.text('동의 화면으로'));
      expect(findText('AI에 보내는 정보'), findsOneWidget);
    });

    testWidgets('연결이 끊긴 실패는 차감되지 않았다고 말하지 않는다', (tester) async {
      // fromServer가 false인 unavailable
      final broken = _OfflineRepo();
      await _open(tester, broken, consent: true);
      await _tap(tester, findText('내 기준으로 자세히 보기'));
      await _tap(tester, find.text('건너뛰고 분석'));
      expect(findText('연결 실패'), findsOneWidget);
      expect(findTextContaining('차감되지 않았습니다'), findsNothing);
    });
  });

  group('크레딧 페이지', () {
    testWidgets('보유·다음 충전·규칙·사용 내역(공고 제목 포함)', (tester) async {
      final repo = _Repo();
      await _open(tester, repo, consent: true);
      await tester.runAsync(() => repo.requestAnalysis(noticeId: _id, requestId: 'a'));
      await tester.pumpWidget(
        MaterialApp(
          theme: gwittimTheme(),
          home: CreditsScreen(repository: repo),
        ),
      );
      await tester.pumpAndSettle();
      expect(findText('4 / 5'), findsOneWidget);
      expect(findText('다음 충전: 내일 0시 (+1)'), findsOneWidget);
      expect(findText('사용 규칙'), findsOneWidget);
      expect(findText('매일 1개 충전, 최대 5개'), findsOneWidget);
      expect(findText('최근 90일'), findsOneWidget);
      expect(findText('+5'), findsOneWidget);
      expect(findText('가입 선물'), findsOneWidget);
      expect(findText('−1'), findsOneWidget);
      expect(findTextContaining('상세 분석 · $_title'), findsOneWidget);
      // 줄을 누르면 받은 분석으로
      await _tap(tester, findTextContaining('상세 분석 · '));
      expect(findText('나와 이 공고'), findsOneWidget);
    });

    testWidgets('최대 보유 문구', (tester) async {
      final repo = _Repo();
      await _open(tester, repo, screen: (r) => CreditsScreen(repository: r));
      expect(findText('5 / 5'), findsOneWidget);
      expect(find.text('최대 보유'), findsOneWidget);
      expect(findText('최대 보유. 사용하면 다음 날부터 다시 충전됩니다.'), findsOneWidget);
    });

    testWidgets('저장본이 없는 분석 줄을 누르면 삭제된 분석 문구', (tester) async {
      final repo = _Repo();
      await _open(tester, repo, consent: true, screen: (r) => CreditsScreen(repository: r));
      await tester.runAsync(() => repo.requestAnalysis(noticeId: _id, requestId: 'a'));
      await repo.withdrawAgentConsent(); // 받은 분석이 지워진다
      await tester.pumpWidget(
        MaterialApp(
          theme: gwittimTheme(),
          home: CreditsScreen(key: UniqueKey(), repository: repo),
        ),
      );
      await tester.pumpAndSettle();
      expect(findText('보관 기간이 지나 삭제된 분석입니다.'), findsNothing);
      await _tap(tester, findTextContaining('상세 분석 · '));
      expect(findText('보관 기간이 지나 삭제된 분석입니다.'), findsOneWidget);
    });

    test('다음 충전 문구는 KST 기준 내일이면 내일, 아니면 날짜', () {
      final now = DateTime.utc(2026, 11, 21, 3); // KST 12시
      Credits at(DateTime? t) => Credits(balance: 2, nextRefillAt: t, entries: const []);
      expect(nextRefillText(at(DateTime.utc(2026, 11, 21, 15)), now: now), '다음 충전: 내일 0시 (+1)');
      expect(nextRefillText(at(DateTime.utc(2026, 11, 22, 15)), now: now), '다음 충전: 11월 23일 0시 (+1)');
      expect(nextRefillText(at(null), now: now), '최대 보유. 사용하면 다음 날부터 다시 충전됩니다.');
    });
  });

  group('내 정보', () {
    Widget profile(SampleNoticeRepository r) =>
        ProfileScreen(repository: r, themeController: ThemeController(), onSaved: () {}, openUrl: (_) async => true);

    testWidgets('크레딧 줄은 남은 개수를 보이고 누르면 크레딧 페이지로 간다', (tester) async {
      await _open(tester, _Repo(), screen: profile);
      expect(findText('이용'), findsOneWidget);
      expect(findText('5 / 5'), findsOneWidget);
      await _tap(tester, findText('크레딧'));
      expect(findText('사용 규칙'), findsOneWidget);
    });

    testWidgets('동의 전에는 철회 줄이 없다', (tester) async {
      await _open(tester, _Repo(), screen: profile);
      expect(findText('AI 상세 분석 동의 철회'), findsNothing);
    });

    testWidgets('철회: 확인 대화상자에서 취소하면 그대로, 철회하면 동의 기록이 지워진다', (tester) async {
      final repo = await _open(tester, _Repo(), consent: true, screen: profile);
      expect((await repo.getProfile()).hasAgentConsent, isTrue);
      await _tap(tester, findText('AI 상세 분석 동의 철회'));
      expect(findText('AI 상세 분석 동의를 철회하시겠습니까?'), findsOneWidget);
      expect(findTextContaining('받은 분석이 모두 삭제'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect((await repo.getProfile()).hasAgentConsent, isTrue);

      await _tap(tester, findText('AI 상세 분석 동의 철회'));
      await tester.tap(find.text('철회'));
      await tester.pumpAndSettle();
      expect((await repo.getProfile())!.agentConsent, isNull);
      expect(findText('AI 상세 분석 동의 철회'), findsNothing);
      expect(find.text('AI 상세 분석 동의가 철회되었습니다.'), findsOneWidget);
    });
  });
}

/// 서버에 닿지 못한 실패
class _OfflineRepo extends SampleNoticeRepository {
  _OfflineRepo() : super(personalized: true);

  @override
  Future<AnalysisResponse> requestAnalysis({
    required String noticeId,
    required String requestId,
    AnalysisChips chips = const AnalysisChips(),
  }) => Future.error(const RepositoryException(RepositoryErrorKind.unavailable));
}
