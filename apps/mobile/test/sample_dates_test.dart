import 'package:flutter_test/flutter_test.dart';
import 'package:gwittim/data/repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('날짜 값은 앞의 날짜만, 글 속 M월 D일은 같이 옮긴다', () {
    final shifted = shiftSampleDates({
      'date': '2026-10-30',
      'at': '2026-10-17T03:05:00Z',
      'list': ['2026-12-30'],
      'summary': '발표회. 10월 30일 17시까지 신청.',
      'title': '2026학년도 경진대회',
      'n': 3,
      'none': null,
    }, 3);
    expect(shifted, {
      'date': '2026-11-02',
      'at': '2026-10-20T03:05:00Z',
      'list': ['2027-01-02'],
      'summary': '발표회. 11월 2일 17시까지 신청.',
      'title': '2026학년도 경진대회',
      'n': 3,
      'none': null,
    });
    expect(shiftSampleDates({'date': '2026-10-30'}, -30), {'date': '2026-09-30'});
  });

  test('오늘을 주면 기준일이 오늘이 되도록 공고 날짜를 옮긴다', () async {
    final today = DateTime(2026, 11, 5);
    final list = await SampleNoticeRepository(today: today).listRecommendations();
    final project = list.items.firstWhere((e) => e.notice.title.contains('프로젝트 발표회')).notice;
    expect(project.applicationDeadline!.day, DateTime(2026, 11, 5)); // 기준일(10/30)에 오늘 마감이던 공고
    expect(list.generatedAt.toUtc(), DateTime.utc(2026, 10, 23, 3, 5));

    final notice = (await SampleNoticeRepository(today: today).getNotice(project.noticeId))!;
    expect(notice.description, contains('11월 5일 17시까지'));

    final original = await SampleNoticeRepository().listRecommendations();
    final same = original.items.firstWhere((e) => e.notice.noticeId == project.noticeId).notice;
    expect(same.applicationDeadline!.day, DateTime(2026, 10, 30)); // 오늘을 안 주면 그대로
  });
}
