// 팀장 폰 수집기: 거르기·가림·분류와 서버로 올리기 대기열 (D-036). 실제 알림은 쓰지 않는다.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/classifier/kakao_classifier.dart';
import 'package:gwittim/classifier/text_model.dart';

import '../tool/notif_probe/collector.dart';

const _models = '../../backend/classifier/models';
const _room = '명지전문대학 공지사항';
const _ai = '[합성 샘플] 2026 교내 AI 데이터 분석 경진대회 참가팀 모집\n대상: 재학생\n문의: 010-1234-5678';

TextModel _load(String name) => TextModel.fromBytes(
  File('$_models/$name.json').readAsStringSync(),
  File('$_models/$name.bin').readAsBytesSync(),
);

final _uri = Uri.parse('https://example.invalid/v1/ingest/kakao');

void main() {
  final classifier = KakaoClassifier(_load(interestModelName), _load(categoryModelName));

  test('모델 버전은 서버 MODEL_VERSION과 같다', () {
    final py = File('../../backend/classifier/cascade.py').readAsStringSync();
    expect(RegExp(r'^MODEL_VERSION = "([^"]+)"', multiLine: true).firstMatch(py)!.group(1), modelVersion);
  });

  test('받은 시각은 내보내기와 같은 분 단위 한국 시각', () {
    // 2026-10-20 05:05:59 UTC = 14:05:59 KST → 초는 버린다
    expect(kstMinute(DateTime.utc(2026, 10, 20, 5, 5, 59).millisecondsSinceEpoch), '2026-10-20T14:05:00+09:00');
    expect(kstMinute(DateTime.utc(2026, 12, 31, 15, 0).millisecondsSinceEpoch), '2027-01-01T00:00:00+09:00');
  });

  test('공통 공지는 가리고 분류해 올릴 값을 만든다', () {
    final p = prepare(classifier, room: _room, postTimeMillis: DateTime.utc(2026, 10, 20, 5, 5).millisecondsSinceEpoch, body: _ai);
    expect(p['kind'], 'broadcast');
    expect(p['text'], contains('<휴대폰>'));
    expect(p['text'], isNot(contains('010-1234-5678')));
    expect(p['sent_at'], '2026-10-20T14:05:00+09:00');
    final c = classifier.classify(p['title'] as String, p['text'] as String);
    expect((p['classification'] as Map)['category'], c.category);
    final body = uploadBody(p);
    expect(body.keys.toSet(), {'room', 'sent_at', 'text', 'model_version', 'classification', 'app_version'});
    expect(body['model_version'], modelVersion);
  });

  test('개인 알림은 공통 공지가 아니다', () {
    final p = prepare(classifier, room: _room, postTimeMillis: 0, body: '[합성 샘플] 데이터베이스 801반 강의를 아직 수강하지 않았습니다.');
    expect(p['kind'], isNot('broadcast'));
  });

  test('이전 알림에 두 번 이상 나온 받는 사람 이름을 가린다', () {
    const history = ['홍길동님 안녕하세요. 합성 안내입니다. 내용을 확인해 주세요.', '홍길동님 합성 알림입니다. 일정을 확인해 주세요.'];
    final p = prepare(classifier, room: _room, postTimeMillis: 0, body: '홍길동님, [합성 샘플] 진로 특강 신청 안내입니다. 모집 기간을 확인해 주세요.', history: history);
    expect(p['text'], isNot(contains('홍길동')));
  });

  group('올리기 대기열', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('collector_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    List<String> lines(String name) {
      final f = File('${dir.path}/$name');
      return f.existsSync() ? f.readAsLinesSync().where((l) => l.isNotEmpty).toList() : [];
    }

    test('올리면 대기열에서 빠지고 기록에는 본문이 없다', () async {
      final sent = <String>[];
      final u = Uploader(dir, CollectorConfig(_uri, 't'), post: (uri, token, json) async {
        expect(token, 't');
        sent.add(json);
        return 200;
      });
      await u.enqueue({'room': _room, 'sent_at': 's', 'text': '가린 본문'});
      expect(await u.flush(), (sent: 1, left: 0));
      expect(sent.single, contains('가린 본문'));
      expect(lines(queueFile), isEmpty);
      expect(lines(uploadedFile).single, isNot(contains('가린 본문')));
    });

    test('연결 실패는 남겨 두고 다음에 다시 올린다', () async {
      var code = 0;
      final u = Uploader(dir, CollectorConfig(_uri, 't'), post: (uri, token, json) async => code);
      await u.enqueue({'room': _room, 'text': 'a'});
      await u.enqueue({'room': _room, 'text': 'b'});
      expect(await u.flush(), (sent: 0, left: 2));
      code = 200;
      expect(await u.flush(), (sent: 2, left: 0));
    });

    test('형식 오류(400)는 다시 올려도 안 되므로 버린다', () async {
      final u = Uploader(dir, CollectorConfig(_uri, 't'), post: (uri, token, json) async => 400);
      await u.enqueue({'room': _room, 'text': 'a'});
      expect(await u.flush(), (sent: 0, left: 0));
      expect(jsonDecode(lines(uploadedFile).single)['status'], 400);
    });

    test('수집 주소가 없으면 올리지 않는다', () async {
      final u = Uploader(dir, const CollectorConfig(null, null), post: (uri, token, json) async => fail('올리면 안 됨'));
      await u.enqueue({'room': _room, 'text': 'a'});
      expect(await u.flush(), (sent: 0, left: 1));
    });
  });
}
