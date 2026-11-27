import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/models.dart';
import 'package:gwittim/data/repository.dart';
import 'package:gwittim/data/shared_notices.dart';
import 'package:gwittim/share/clipboard_suggest.dart';
import 'package:gwittim/share/image_pick.dart';
import 'package:gwittim/share/share_inbox.dart';
import 'package:gwittim/share/share_prepare.dart';
import 'package:gwittim/share/share_services.dart';
import 'package:gwittim/share/text_ocr.dart';
import 'package:gwittim/ui/briefing_data.dart';
import 'package:gwittim/ui/home_screen.dart';
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

class _FakePicker implements ShareImagePicker {
  _FakePicker(this.path);

  final String? path;
  int calls = 0;

  @override
  Future<String?> pick() async {
    calls++;
    return path;
  }
}

class _FakeClip implements ClipboardSource {
  _FakeClip(this.text);

  String? text;
  int reads = 0;

  @override
  Future<bool> hasStrings() async => text != null;

  @override
  Future<String?> readText() async {
    reads++;
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

  group('복사한 글 제안', () {
    Future<(_FakeClip, MemorySuggestMemory)> pumpHome(
      WidgetTester tester,
      String? clip, {
      List<String>? seen,
    }) async {
      final repo = _ShareRepo();
      final fake = _FakeClip(clip);
      final memory = MemorySuggestMemory(seen);
      await _pump(
        tester,
        Scaffold(
          body: HomeScreen(
            repository: repo,
            openUrl: (_) async => true,
            briefingStore: MemoryBriefingStore(alwaysShown: true),
            today: DateTime(2026, 11, 26),
            share: ShareServices(
              inbox: ShareInbox(),
              ocr: _FakeOcr(_notice),
              consent: MemoryShareConsentStore(shareConsentVersion),
              suggester: ClipboardSuggester(clipboard: fake, memory: memory),
            ),
          ),
        ),
        repo,
      );
      return (fake, memory);
    }

    testWidgets('공고 글이면 카드가 보이고, 불러오기로 확인 화면을 연다(보내지 않음)', (tester) async {
      await pumpHome(tester, _notice);
      expect(findText('복사한 알림톡'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('clip-preview'))).data,
        startsWith('[합성 샘플] 취업 역량'),
      );
      await tester.tap(find.byKey(const ValueKey('clip-load')));
      await tester.pumpAndSettle();
      expect(findText('넘길 공고 확인'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('share-input')))
            .controller!
            .text,
        _notice,
      );
    });

    testWidgets('넘기기 카드는 홈 맨 위에 하나만 있고, 제안이 있을 때만 같은 카드 안에 제안이 붙는다', (tester) async {
      await pumpHome(tester, _notice);
      final card = find.byType(ShareEntryCard);
      expect(card, findsOneWidget);
      for (final key in ['clip-load', 'clip-close', 'share-pick-image', 'share-paste']) {
        expect(
          find.descendant(of: card, matching: find.byKey(ValueKey(key))),
          findsOneWidget,
          reason: key,
        );
      }
      // 제안 줄이 캡처 고르기보다 위, 카드는 마감 구역보다 위
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('clip-load'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('share-pick-image'))).dy),
      );
      expect(
        tester.getBottomLeft(card).dy,
        lessThan(tester.getTopLeft(findText('이번 주 마감')).dy),
      );
      expect(tester.getTopLeft(card).dy, lessThan(300));

      await pumpHome(tester, null);
      expect(find.byType(ShareEntryCard), findsOneWidget);
      expect(find.byKey(const ValueKey('clip-load')), findsNothing);
      expect(find.byKey(const ValueKey('share-pick-image')), findsOneWidget);
      expect(findText('복사한 알림톡'), findsNothing);
    });

    testWidgets('닫으면 기억하고, 닫은 글은 다시 제안하지 않는다', (tester) async {
      final (_, memory) = await pumpHome(tester, _notice);
      await tester.tap(find.byKey(const ValueKey('clip-close')));
      await tester.pumpAndSettle();
      expect(findText('복사한 알림톡'), findsNothing);
      expect(await memory.read(), hasLength(1));
      await pumpHome(tester, _notice, seen: await memory.read());
      expect(findText('복사한 알림톡'), findsNothing);
    });

    testWidgets('짧은 글·개인 알림·공고 말이 없는 글·빈 클립보드는 제안하지 않는다', (tester) async {
      for (final t in [
        '짧은 글입니다 12월 3일',
        '[합성 과목] 합성프로그래밍 801반 학습 안내입니다.\n아직 수강하지 않았습니다. 수강기한 안에 수강해 주세요.',
        '오늘 점심은 학생식당에서 먹고 도서관에서 공부했습니다 날씨가 좋았습니다',
        null,
      ]) {
        final (fake, _) = await pumpHome(tester, t);
        expect(findText('복사한 알림톡'), findsNothing, reason: '$t');
        if (t == null) expect(fake.reads, 0); // 있는지부터 보고 없으면 읽지 않는다
      }
    });

    test('iOS 방식(readOnCheck: false)은 열 때 내용을 읽지 않고, 불러올 때 읽는다', () async {
      final fake = _FakeClip('[시험] 겨울방학 SW 캠프 참가자 모집 안내. 신청 기간: 12월 10일(수)까지');
      final s = ClipboardSuggester(clipboard: fake, memory: MemorySuggestMemory(), readOnCheck: false);
      final got = await s.check();
      expect(got, isNotNull);
      expect(got!.unread, isTrue);
      expect(got.firstLine, isNull);
      expect(fake.reads, 0); // '붙여넣기 허용' 창을 띄우지 않는다
      expect(await s.readFor(got), contains('12월 10일'));
      expect(fake.reads, 1);

      final empty = ClipboardSuggester(clipboard: _FakeClip(null), memory: MemorySuggestMemory(), readOnCheck: false);
      expect(await empty.check(), isNull);
    });

    test('가린 본문 해시는 공백이 달라도 같고, 20개까지만 남긴다', () async {
      expect(clipHash('가 나\n다'), clipHash('가  나 다'));
      final memory = MemorySuggestMemory();
      final s = ClipboardSuggester(clipboard: _FakeClip(null), memory: memory);
      for (var i = 0; i < 25; i++) {
        await s.remember('h$i');
      }
      final saved = await memory.read();
      expect(saved, hasLength(20));
      expect(saved.first, 'h5');
    });
  });

  group('홈', () {
    testWidgets('진입 카드에서 바로 캡처 고르기·붙여넣기를 열 수 있고, 샘플 자료에서는 없다', (tester) async {
      final repo = _ShareRepo();
      final picker = _FakePicker(null);
      await _pump(
        tester,
        Scaffold(
          body: HomeScreen(
            repository: repo,
            openUrl: (_) async => true,
            briefingStore: MemoryBriefingStore(alwaysShown: true),
            today: DateTime(2026, 11, 26),
            share: ShareServices(
              inbox: ShareInbox(),
              ocr: _FakeOcr(_notice),
              consent: MemoryShareConsentStore(shareConsentVersion),
              picker: picker,
            ),
          ),
        ),
        repo,
      );
      expect(findText('카톡 공고 넘기기'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('share-pick-image')));
      await tester.pumpAndSettle();
      expect(picker.calls, 1);
      await tester.tap(find.byKey(const ValueKey('share-paste')));
      await tester.pumpAndSettle();
      expect(findText('넘길 공고 확인'), findsOneWidget);

      final plain = SampleNoticeRepository(personalized: true);
      await tester.runAsync(plain.preload);
      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          theme: gwittimTheme(),
          home: Scaffold(
            body: HomeScreen(
              repository: plain,
              openUrl: (_) async => true,
              briefingStore: MemoryBriefingStore(alwaysShown: true),
              today: DateTime(2026, 11, 26),
              share: _services(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(findText('카톡 공고 넘기기'), findsNothing);
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

    testWidgets('캡처 이미지 고르기: 고른 이미지를 글자 인식해 확인 화면으로 열고 파일은 지운다', (tester) async {
      final repo = _ShareRepo();
      final ocr = _FakeOcr(_notice);
      final file = File('${Directory.systemTemp.path}/gwittim_pick_test.png')
        ..writeAsBytesSync([1, 2, 3]);
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });
      final picker = _FakePicker(file.path);
      await _pump(
        tester,
        Scaffold(
          body: SavedScreen(
            repository: repo,
            openUrl: (_) async => true,
            today: DateTime(2026, 11, 26),
            share: ShareServices(
              inbox: ShareInbox(),
              ocr: ocr,
              consent: MemoryShareConsentStore(shareConsentVersion),
              picker: picker,
            ),
          ),
        ),
        repo,
      );
      await tester.tap(find.byKey(const ValueKey('share-pick-image')));
      await tester.pumpAndSettle();
      expect(picker.calls, 1);
      expect(ocr.paths, [file.path]);
      expect(findText('넘길 공고 확인'), findsOneWidget);
      expect(findText('인식한 글자가 틀릴 수 있습니다. 확인 뒤 보내십시오.'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('share-input')))
            .controller!
            .text,
        _notice,
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      ); // 실제 파일 삭제가 끝나길 기다림
      await tester.runAsync(() async {
        for (var i = 0; i < 5 && file.existsSync(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      });
      expect(file.existsSync(), isFalse); // 인식 뒤 지운다
      expect(repo.sent, isEmpty); // 보내기 전에는 서버로 가지 않는다
      await tester.tap(find.text('보내기'));
      await tester.pumpAndSettle();
      expect(repo.sent.single.input, ShareInput.imageOcr);
      expect(repo.sent.single.ocrEdited, isFalse);
    });

    testWidgets('캡처 이미지 고르기: 선택을 취소하면 아무것도 하지 않는다', (tester) async {
      final repo = _ShareRepo();
      final ocr = _FakeOcr(_notice);
      final picker = _FakePicker(null);
      await _pump(
        tester,
        Scaffold(
          body: SavedScreen(
            repository: repo,
            openUrl: (_) async => true,
            today: DateTime(2026, 11, 26),
            share: ShareServices(
              inbox: ShareInbox(),
              ocr: ocr,
              consent: MemoryShareConsentStore(shareConsentVersion),
              picker: picker,
            ),
          ),
        ),
        repo,
      );
      await tester.tap(find.byKey(const ValueKey('share-pick-image')));
      await tester.pumpAndSettle();
      expect(picker.calls, 1);
      expect(ocr.paths, isEmpty);
      expect(findText('넘길 공고 확인'), findsNothing);
      expect(findText('캡처 고르기'), findsOneWidget);
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
