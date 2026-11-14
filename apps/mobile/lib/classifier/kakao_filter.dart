// 알림톡 종류 판정(공통 공지·개인 알림)과 개인정보 가림을 기기 안에서 한다 (D-034).
//
// backend/collectors/mjc_kakao/parser.py의 clean_body·detect_names·classify·mask·title_of와 같은 결과를 내야 한다.
// 같은지는 test/kakao_filter_test.dart가 파서로 만든 골든(backend/collectors/mjc_kakao/tests/filter_golden.json)으로,
// 실제 내보내기 전체는 tool/kakao_filter_parity.dart가 검사한다.
//
// 파이썬 정규식과 다른 점을 맞춘 곳
//   \s, str.strip(), str.splitlines()  공백·줄 바꿈 문자 범위가 Dart와 달라 직접 적는다 (_space, _pyStrip, _pySplitLines)
//   \d, \w                              파이썬은 Unicode 기준: \p{Nd}, [\p{L}\p{N}_] (unicode: true)
//   .                                  파이썬은 \n만 빼고, Dart는 \r·U+2028·U+2029도 뺀다 → [^\n]
// 이 파일은 Flutter를 쓰지 않는다.

/// 파이썬 \s와 str.isspace()가 공백으로 보는 문자
const String _space =
    '\\t\\n\\u000b\\u000c\\r\\u001c-\\u001f \\u0085\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000';
const String _s = '[$_space]';
const String _notS = '[^$_space]';
const String _d = '\\p{Nd}';
const String _notW = '[^\\p{L}\\p{N}_]';

RegExp _re(String pattern) => RegExp(pattern, unicode: true);

/// 파이썬 str.splitlines()가 줄을 나누는 문자 (\r\n은 한 번)
final RegExp _lineBreak = _re('\\r\\n|[\\n\\u000b\\u000c\\r\\u001c-\\u001e\\u0085\\u2028\\u2029]');
final RegExp _edgeSpace = _re('^$_s+|$_s+\$');
final RegExp _trailingSpace = _re('$_s+\$');
final RegExp _spaces = _re('$_s+');

List<String> _pySplitLines(String text) {
  if (text.isEmpty) return const [];
  final lines = text.split(_lineBreak);
  // 파이썬은 끝의 줄 바꿈 뒤에 빈 줄을 만들지 않는다 (split의 마지막 빈 조각은 글이 줄 바꿈으로 끝났다는 뜻)
  if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
  return lines;
}

String _pyStrip(String s) => s.replaceAll(_edgeSpace, '');

const List<String> boilerplate = [
  '관리자가 없을때 대신 답변하는 채널 AI에요.',
  '채널 관리자가 없을 때 제가 대신 답변해 드려요.',
  '카나나 상담매니저가 문의에 응대하는 채널입니다. 답변 내용은 해당 채널에서 관리합니다.',
];
const List<String> _botGreetings = ['상담매니저예요', '채널 AI 매니저예요'];
final RegExp _course = _re('[가-힣A-Za-z0-9·Ⅰ-Ⅹ\\-]+ ?$_d{3}반');
const List<String> _courseWords = ['아직 수강하지 않았습니다', '미제출', '미응시', '출석률', '수강기한', '온에어'];
final RegExp _account = _re('결과$_s*:|완료되었');
final RegExp _studentId = _re('(?<!$_d)20$_d{8}(?!$_d)');
final RegExp _recipientId = _re('(?<!$_d)20$_d{8}$_s*학생');
final RegExp _template = _re('#\\{[^}]*\\}');
final RegExp _participant = _re(
  '(신청|참여)(해|하여) ?주(셔서|신) 감사'
  '|참여하고 계신|튜터/튜티|튜터분들'
  '|(참여|신청) ?학생(들)? ?(전체를 ?)?(대상|여러분|들에게|들은)'
  '|(진행된|진행되었던|완료됨에 따라|완료에 따라|종료 안내)[^\\n]{0,40}만족도'
  '|대상 ?: ?[^.\\n]{0,20}참여자'
  '|수료 ?현황|학습시간 현황|제출 ?현황|신청 및 승인이|신청 확정|수료 ?조건 필수|학습컨설턴트 ?:'
  '|참여가 어려운|참석이 어려우신 경우',
);
final RegExp _recruit = _re('모집|신청 ?안내|신청 ?기간|신청 ?방법|신청 ?마감|빠른 ?신청|까지 신청');
final RegExp _fillerLine = _re('^(\\[[^\\]]*\\]|안녕하세요[^\\n]*|문의[^\\n]*)\$');
final RegExp _mobile = _re('01[016789]-?$_d{3,4}-?$_d{4}');
final RegExp _profAfterLabel = _re('((?:담당|책임)교수$_s*:?$_s*)[가-힣]{3}');
final RegExp _profBeforeTitle = _re('[가-힣]{3}(?=$_s?교수(?:입니다|님|\\]))');
final RegExp _honorific = _re('([가-힣]{2,4})님');
const Set<String> _notNames = {'학생', '교수', '선생', '담당자', '여러분', '고객', '회원', '사용자', '참여자', '신청자', '재학생', '학우'};
final RegExp _greeting = _re('^$_notW*안녕하세요$_notW*(?:<?이름>?$_s*님$_notW*)?');
final RegExp _intro = _re(
  '^$_notW*(?:명지전문대학$_s*)?[가-힣A-Za-z·$_space]{0,20}(?:센터|팀|실|과|처|원|단|관|본부|위원회|대학)$_s*'
  '(?:입니다|에서$_s*안내(?:해)?$_s*드립니다)$_notW*',
);
final RegExp _skipTitle = _re(
  '^$_notW*저는$_s[^\\n]*봇$_notW*입니다|발송되는$_s*메[세시]지|^$_notW*즐거운$_s*$_notS+$_s*입니다$_notW*\$'
  '|^$_notW*<?이름>?$_s*님$_notW*\$',
);
final RegExp _bracketOnly = _re('^\\[[^\\]]*\\]\$');
final RegExp _manyBlankLines = _re('\\n{3,}');

/// 알림톡 종류. 게시·추천 대상은 broadcast뿐이다.
abstract final class KakaoKind {
  static const broadcast = 'broadcast'; // 학생 전체·다수 대상 공지
  static const personalCourse = 'personal_course'; // 수강 과목 알림 (미수강·미제출·출석률)
  static const personalAccount = 'personal_account'; // 이름·학번이 들어간 개인 알림
  static const participant = 'participant'; // 신청·참여한 학생에게만 보낸 운영 안내
  static const noise = 'noise'; // 채널 자동응답·빈 템플릿
}

/// 채널 자동응답 문구와 빈 템플릿 칸(#{...})을 빼고 빈 줄을 줄인다 (parser.clean_body).
String cleanBody(String raw) {
  final out = [
    for (final l in _pySplitLines(raw))
      if (!boilerplate.contains(_pyStrip(l))) l.replaceAll(_trailingSpace, ''),
  ];
  final text = _pyStrip(out.join('\n').replaceAll(_template, ''));
  return text.replaceAll(_manyBlankLines, '\n\n');
}

/// 여러 알림에 두 번 이상 나온 '○○○님'을 받는 사람 이름으로 본다 (parser.detect_names).
/// 기기에서는 지금까지 받은 학교 채널 알림 본문을 넘긴다.
Set<String> detectNames(Iterable<String> texts) {
  final count = <String, int>{};
  for (final t in texts) {
    for (final n in {for (final m in _honorific.allMatches(t)) m.group(1)!}) {
      count[n] = (count[n] ?? 0) + 1;
    }
  }
  return {
    for (final e in count.entries)
      if (e.value >= 2 && !_notNames.contains(e.key) && e.key.runes.length == 3) e.key,
  };
}

/// 알림톡 종류 판정 (parser.classify). [text]는 cleanBody를 거친 본문.
String kakaoKind(String text, Set<String> names) {
  final body = text.replaceAll(_spaces, ' ');
  final content = [
    for (final l in _pySplitLines(text))
      if (!_fillerLine.hasMatch(_pyStrip(l))) l,
  ].join();
  if (_pyStrip(content).runes.length < 15 || _botGreetings.any(body.contains)) return KakaoKind.noise;
  if (_recipientId.hasMatch(body) || (names.any(body.contains) && _account.hasMatch(body))) {
    return KakaoKind.personalAccount;
  }
  const courseNotice = ['공지사항을 다음과 같이', '안내입니다'];
  if (_course.hasMatch(body) && (_courseWords.any(body.contains) || courseNotice.any(body.contains))) {
    return KakaoKind.personalCourse;
  }
  if (_courseWords.any(body.contains)) return KakaoKind.personalCourse;
  if (_participant.hasMatch(body) && !_recruit.hasMatch(body)) return KakaoKind.participant;
  return KakaoKind.broadcast;
}

/// 학번·휴대폰·교수 이름·받는 사람 이름을 가린다 (parser.mask).
String maskPersonal(String text, Iterable<String> names) {
  var out = text.replaceAll(_studentId, '<학번>').replaceAll(_mobile, '<휴대폰>');
  out = out.replaceAllMapped(_profAfterLabel, (m) => '${m.group(1)}<교수>');
  out = out.replaceAll(_profBeforeTitle, '<교수>');
  for (final n in names.toList()..sort()) {
    out = out.replaceAll(n, '<이름>');
  }
  return out;
}

/// 제목: 인사·부서 소개·발송 안내 줄을 건너뛴 첫 줄, 80자까지 (parser.title_of). [text]는 가린 본문.
String kakaoTitle(String text, String room) {
  final shortRoom = _pyStrip(room.replaceAll('명지전문대학', ''));
  for (final l in _pySplitLines(text)) {
    var s = _pyStrip(l);
    if (s.isEmpty || _bracketOnly.hasMatch(s) || s == room || s == shortRoom || _skipTitle.hasMatch(s)) {
      continue;
    }
    s = _pyStrip(s.replaceFirst(_greeting, '').replaceFirst(_intro, ''));
    if (s.isNotEmpty) {
      final runes = s.runes.toList();
      return runes.length <= 80 ? s : String.fromCharCodes(runes.take(80));
    }
  }
  return '';
}
