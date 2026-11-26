import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/data/shared_notices.dart';
import 'package:gwittim/share/share_inbox.dart';
import 'package:gwittim/share/share_prepare.dart';
import 'package:gwittim/share/share_services.dart';
import 'package:gwittim/share/text_ocr.dart';
import 'package:gwittim/ui/saved_screen.dart';
import 'package:gwittim/ui/share_flow.dart';
import 'package:gwittim/ui/theme.dart';

import 'finders.dart';

// 카카오톡 공고 넘기기 (D-058). 합성 글만 쓴다.

const _notice =
    '[합성 샘플] 취업 역량 강화 특강 안내\n'
    '- 신청 기간: 12월 3일(목)까지\n'
    '- 특강 일시: 12월 10일(목) 14시\n'
    '- 대상: 재학생 누구나\n'
    '- 문의: 학번 2024123456, 010-1234-5678';

SharedNoticeItem _item() {
  final json = jsonDecode(
    File('../../fixtures/valid/shared_notice_response/item.json')
        .readAsStringSync(),
  );
  return SharedNoticeItem.fromJson(json as Map<String, dynamic>);
}

class _FakeOcr implements TextOcr {
  _FakeOcr(this.text);

  final String text;
  final paths = <String>[];

  @override
  Future<String> recognize(String imagePath) async {
    paths.add(imagePath);
    return text;
  }
}

class _ShareRepo extends SampleNoticeRepository implements SharedNoticeApi {
  _ShareRepo() : super(personalized: true);

  final sent = <({String text, ShareInput input, bool? ocrEdited})>[];
  final deleted = <String>[];
  List<SharedNoticeItem> items = [];
  bool personal = false;

  @override
  Future<SubmitSharedResult> submitShared({
    required String text,
    required ShareInput input,
    bool? ocrEdited,
  }) async {
    sent.add((text: text, input: input, ocrEdited: ocrEdited));
    return SubmitSharedResult(personal ? null : _item());
  }

  @override
  Future<List<SharedNoticeItem>> listShared() async => items;

  @override
  Future<void> deleteShared(String id) async {
    deleted.add(id);
    items = [
      for (final i in items)
        if (i.id != id) i,
    ];
  }
}

ShareServices _services({String ocrText = '', String? consentVersion}) =>
    ShareServices(
      inbox: ShareInbox(),
      ocr: _FakeOcr(ocrText),
      consent: MemoryShareConsentStore(consentVersion),
    );

Future<void> _pump(WidgetTester tester, Widget home, _ShareRepo repo) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(repo.preload);
  await tester.pumpWidget(MaterialApp(key: UniqueKey(), theme: gwittimTheme(), home: home));
  await tester.pumpAndSettle();
}

Widget _confirm(
  _ShareRepo repo,
  ShareServices share, {
  String text = '',
  ShareInput input = ShareInput.paste,
  String? image,
}) => ShareConfirmScreen(
  key: UniqueKey(),
  repository: repo,
  openUrl: (_) async => true,
  share: share,
  input: input,
  initialText: text,
  imagePath: image,
  today: DateTime(2026, 11, 26),
);

void main() {
  group('보내기 전 가리기', () {
    test('학번·휴대폰을 가리고 개수를 센다', () {
      final prep = prepareShare(_notice);
      expect(prep.masked, contains('<학번>'));
      expect(prep.masked, contains('<휴대폰>'));
      expect(prep.masked, isNot(contains('2024123456')));
      expect(prep.masked, isNot(contains('010-1234-5678')));
      expect(prep.maskedCount, 2);
      expect(prep.sendable, isTrue);
    });

    test('개인 알림·잡음은 보낼 수 없다, 참여 학생 안내는 보낼 수 있다', () {
      expect(
        prepareShare(
          '[합성 과목] 합성프로그래밍 801반 학습 안내입니다.\n아직 수강하지 않았습니다. 수강기한 안에 수강해 주세요.',
        ).isPersonal,
        isTrue,
      );
      expect(
        prepareShare('[합성 센터] 합성 결과 안내\n2024000001 학생의 결과: 합격 처리가 완료되었습니다.')
            .isPersonal,
        isTrue,
      );
      expect(
        prepareShare('안녕하세요. 합성 센터입니다.\n문의: 합성센터 000-0000\n[합성 센터]').isPersonal,
        isTrue,
      );
      expect(
        prepareShare('[합성 센터] 합성 프로그램에 참여해 주셔서 감사합니다. 다음 주 일정을 안내합니다.')
            .isPersonal,
        isFalse,
      );
    });

    test('너무 짧은 글은 보낼 수 없다', () {
      expect(prepareShare('짧은 글').sendable, isFalse);
    });
  });

  group('공유 받기', () {
    test('네이티브 값을 글·이미지로 읽는다', () {
      expect(
        (parseShare({'kind': 'text', 'text': '합성 글'}) as SharedText).text,
        '합성 글',
      );
      expect(
        (parseShare({
          'kind': 'image',
          'path': '/cache/a.img',
        }) as SharedImage).path,
        '/cache/a.img',
      );
      expect(parseShare({'kind': 'text', 'text': '  '}), isNull);
      expect(parseShare({'kind': 'video'}), isNull);
    });

    testWidgets('콜드 스타트로 받은 공유를 한 번만 넘겨준다', (tester) async {
      const channel = MethodChannel('kr.gwittim.gwittim/share');
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls++;
            return calls == 1 ? {'kind': 'text', 'text': '합성 공유 글'} : null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final inbox = ShareInbox(channel: channel);
      await inbox.start();
      expect((inbox.consume() as SharedText).text, '합성 공유 글');
      expect(inbox.consume(), isNull);
    });
  });

  group('확인 화면', () {
    testWidgets('가려지는 부분을 미리 보이고, 동의 전에는 보내지 않는다', (tester) async {
      final repo = _ShareRepo();
      final share = _services();
      await _pump(
        tester,
        _confirm(repo, share, text: _notice, input: ShareInput.text),
        repo,
      );
      expect(findText('학번·휴대폰·교수 이름·받는 사람 이름 2곳을 가렸습니다.'), findsOneWidget);
      final preview = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('share-preview')),
          matching: find.byType(Text),
        ),
      );
      expect(
        preview.textSpan!.toPlainText(),
        allOf(
          contains('<학번>'),
          contains('<휴대폰>'),
          isNot(contains('2024123456')),
        ),
      );

      await tester.tap(find.text('보내기'));
      await tester.pumpAndSettle();
      expect(findText('카톡 공고 넘기기 안내'), findsOneWidget);
      await tester.tap(find.text('동의하지 않음'));
      await tester.pumpAndSettle();
      expect(repo.sent, isEmpty); // 동의 전에는 서버로 보내지 않는다
      expect(await share.consent.readVersion(), isNull);
    });

    testWidgets('동의하면 가린 글만 보내고 결과 화면을 연다', (tester) async {
      final repo = _ShareRepo();
      final share = _services();
      await _pump(
        tester,
        _confirm(repo, share, text: _notice, input: ShareInput.text),
        repo,
      );
      await tester.tap(find.text('보내기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('동의하고 보내기'));
      await tester.pumpAndSettle();
      expect(repo.sent, hasLength(1));
      expect(repo.sent.single.input, ShareInput.text);
      expect(repo.sent.single.ocrEdited, isNull);
      expect(
        repo.sent.single.text,
        allOf(
          contains('<학번>'),
          isNot(contains('2024123456')),
          isNot(contains('010-1234-5678')),
        ),
      );
      expect(await share.consent.readVersion(), shareConsentVersion);
      expect(findText('카카오톡에서 넘긴 공고'), findsWidgets); // 결과 화면 출처 표시
      expect(findTextContaining('원문 링크가 없습니다'), findsOneWidget);
    });

    testWidgets('이미 동의했으면 바로 보낸다. 개인 알림은 보내기가 막힌다', (tester) async {
      final repo = _ShareRepo();
      final share = _services(consentVersion: shareConsentVersion);
      await _pump(
        tester,
        _confirm(repo, share, text: _notice, input: ShareInput.paste),
        repo,
      );
      await tester.tap(find.text('보내기'));
      await tester.pumpAndSettle();
      expect(repo.sent, hasLength(1));
      expect(repo.sent.single.input, ShareInput.paste);

      final personal = _ShareRepo();
      await _pump(
        tester,
        _confirm(
          personal,
          share,
          text:
              '[합성 과목] 합성프로그래밍 801반 학습 안내입니다.\n아직 수강하지 않았습니다. 수강기한 안에 수강해 주세요.',
        ),
        personal,
      );
      expect(findText('개인 알림이라 분류하지 않습니다.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '보내기'))
            .onPressed,
        isNull,
      );
    });

    testWidgets('캡처 이미지는 글자 인식 뒤 입력칸에 넣고, 고치면 수정으로 표시한다', (tester) async {
      final repo = _ShareRepo();
      final ocr = _FakeOcr(_notice);
      final share = ShareServices(
        inbox: ShareInbox(),
        ocr: ocr,
        consent: MemoryShareConsentStore(shareConsentVersion),
      );
      await _pump(
        tester,
        _confirm(
          repo,
          share,
          input: ShareInput.imageOcr,
          image: '/cache/none.img',
        ),
        repo,
      );
      expect(ocr.paths, ['/cache/none.img']);
      expect(findText('인식한 글자가 틀릴 수 있습니다. 확인 뒤 보내십시오.'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('share-input')))
            .controller!
            .text,
        _notice,
      );

      await tester.enterText(
        find.byKey(const ValueKey('share-input')),
        '$_notice\n- 장소: 합성관 101호',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('보내기'));
      await tester.pumpAndSettle();
      expect(repo.sent.single.input, ShareInput.imageOcr);
      expect(repo.sent.single.ocrEdited, isTrue);
    });
  });

  group('저장 탭', () {
    testWidgets('진입과 넘긴 공고 묶음이 보이고 삭제할 수 있다', (tester) async {
      final repo = _ShareRepo()..items = [_item()];
      await _pump(
        tester,
        Scaffold(
          body: SavedScreen(
            repository: repo,
            openUrl: (_) async => true,
            today: DateTime(2026, 11, 26),
            share: _services(),
          ),
        ),
        repo,
      );
      expect(findText('카톡 공고 넘기기'), findsOneWidget);
      expect(findText('카톡에서 넘긴 공고'), findsOneWidget);
      await tester.tap(
        find.byKey(ValueKey('shared-delete-${repo.items.single.id}')),
      );
      await tester.pumpAndSettle();
      expect(repo.deleted, ['synthetic-share-0001']);
      expect(findText('카톡에서 넘긴 공고'), findsNothing);
    });

    testWidgets('넘기기를 지원하지 않는 저장소·공유 도구가 없으면 진입이 없다', (tester) async {
      final repo = _ShareRepo();
      await _pump(
        tester,
        Scaffold(
          body: SavedScreen(
            repository: repo,
            openUrl: (_) async => true,
            today: DateTime(2026, 11, 26),
          ),
        ),
        repo,
      );
      expect(findText('카톡 공고 넘기기'), findsNothing);
    });
  });
}
