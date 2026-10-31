import 'package:flutter/widgets.dart' show StringCharacters;

import '../data/models.dart';

const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

/// 날짜 정보 표시. 시각이 확인된 경우에만 시각을 보여준다 (SPEC §5: 날짜만 확인된 당일에 임의 마감시각 금지).
String formatDateInfo(DateInfo info) {
  final d = info.day;
  final base = '${d.year}년 ${d.month}월 ${d.day}일 (${_weekdays[d.weekday - 1]})';
  if (!info.hasTime) return base;
  final zone = info.timezone == null ? ' (시간대 미확인)' : '';
  return '$base ${info.time}$zone';
}

/// 마감 표시: 확정 날짜가 없으면 원문 설명(선착순 등), 둘 다 없으면 '마감일 미상'.
String deadlineLabel(NoticeSummary n) {
  final d = n.applicationDeadline;
  if (d != null) return '마감 ${formatDateInfo(d)}';
  if (n.deadlineNote != null) return n.deadlineNote!;
  return '마감일 미상';
}

/// 남은 날짜 표시. 날짜 단위로만 계산한다.
String? daysLeftLabel(NoticeSummary n, DateTime today) {
  final d = n.applicationDeadline;
  if (d == null || n.lifecycleStatus != 'open') return null;
  final days = d.day.difference(DateTime(today.year, today.month, today.day)).inDays;
  if (days < 0) return null;
  return days == 0 ? '오늘 마감' : 'D-$days';
}

String lifecycleLabel(String status) => switch (status) {
  'open' => '모집 중',
  'closed' => '마감',
  'removed' => '삭제된 공고',
  _ => '상태 미확인',
};

String eligibilityLabel(String status) => switch (status) {
  'met' => '지원 조건 충족',
  'not_met' => '지원 조건 미충족',
  _ => '조건 확인 필요',
};

/// reason_codes 공통 템플릿 (SPEC §5·§6). '관심 분야 관련'과 '지원 조건 충족'을 구분한다.
String reasonText(String code) => switch (code) {
  'interest_match' => '관심 분야 연관 공고',
  'role_match' => '희망 직무 연관 공고',
  'major_match' => '전공 연관 공고',
  'major_prior_match' => '학과 졸업생이 많이 가는 분야의 공고',
  'deadline_timing' => '2주 안에 신청 마감',
  'eligibility_met' => '확인된 지원 조건 모두 충족',
  'eligibility_needs_check' => '지원 조건 원문 확인 필요',
  _ => '',
};

String conditionFieldLabel(String field) => switch (field) {
  'university_id' => '학교',
  'major_id' => '학과',
  'grade' => '학년',
  'enrollment_status' => '재학 상태',
  _ => field,
};

/// D-006: 원문 마지막 확인이 24시간을 넘으면 안내한다. 정상이면 null.
String? staleNotice(DateTime? lastVerifiedAt, DateTime now) {
  if (lastVerifiedAt == null) return '원문 확인 시각을 알 수 없습니다. 지원 전에 원문을 확인해 주세요.';
  final hours = now.difference(lastVerifiedAt).inHours;
  if (hours < 24) return null;
  final ago = hours < 48 ? '$hours시간' : '${hours ~/ 24}일';
  return '$ago 전에 마지막으로 확인했습니다. 이후 내용이 바뀌었을 수 있습니다.';
}

/// 짧은 날짜: "10월 30일(금)", 시각이 확인된 경우에만 " 17:00"을 붙인다.
String shortDate(DateInfo info) {
  final base = shortDay(info.day);
  return info.hasTime ? '$base ${info.time}' : base;
}

String shortDay(DateTime d) => '${d.month}월 ${d.day}일(${_weekdays[d.weekday - 1]})';

String weekdayName(DateTime d) => _weekdays[d.weekday - 1];

/// 모집 중이고 확정 마감이 오늘 이후면 남은 날 수. 아니면 null.
int? daysLeft(NoticeSummary n, DateTime today) {
  final d = n.applicationDeadline;
  if (d == null || n.lifecycleStatus != 'open') return null;
  final days = d.day.difference(DateTime(today.year, today.month, today.day)).inDays;
  return days < 0 ? null : days;
}

/// 목록 칩용 짧은 조건 상태
String eligibilityShort(String status) => switch (status) {
  'met' => '조건 충족',
  'not_met' => '조건 미충족',
  _ => '조건 확인 필요',
};

/// 개인화 추천 이유 코드 → 화면 낱말 (형광펜으로 강조)
const personalReasons = {
  'interest_match': '관심 분야',
  'role_match': '희망 직무',
  'major_match': '전공',
  'major_prior_match': '학과 졸업생 진로', // D-020
};

const _wordJoiner = '\u2060'; // 보이지 않고, 이 자리에서는 줄을 바꾸지 않는다
const _noBreakSpace = '\u00A0';
final _sentenceEnd = RegExp(r'[.!?]$');

/// 문장을 어절 단위로만 줄바꿈한다(CSS `word-break: keep-all`).
/// Flutter는 한글 음절 사이에서도 줄을 바꿔 '주세\n요.'처럼 어절이 갈라진다.
/// - 어절 안 글자 사이에 단어 연결자를 넣어 띄어쓰기에서만 줄이 바뀌게 한다.
/// - 끝 문장이 짧으면(14자 이하) 통째로, 아니면 끝 두 어절을 묶어 다음 줄에 한 어절만 남지 않게 한다.
String keepAll(String text) => text.split('\n').map(_keepAllLine).join('\n');

String _keepAllLine(String line) {
  final words = line.split(' ');
  var bind = 2;
  final end = words.lastIndexWhere(_sentenceEnd.hasMatch, words.length - 2);
  if (end >= 0 && words.length - end - 1 > bind && words.skip(end + 1).join(' ').length <= 14) {
    bind = words.length - end - 1;
  }
  final joined = words.map(_joinWord).toList();
  final split = (words.length - bind).clamp(0, words.length);
  return [...joined.take(split), joined.skip(split).join(_noBreakSpace)].join(' ');
}

/// 글자 사이에 단어 연결자를 넣는다. 글자는 화면 글자 단위(자모 조합·이모지가 갈라지지 않게)로 나눈다.
/// 영문·숫자·기호끼리는 원래 규칙대로 둔다(URL은 '/', '?'에서 줄이 바뀌도록).
String _joinWord(String word) {
  final out = StringBuffer();
  String? prev;
  for (final c in word.characters) {
    if (prev != null && !(_isAscii(prev) && _isAscii(c))) out.write(_wordJoiner);
    out.write(c);
    prev = c;
  }
  return out.toString();
}

bool _isAscii(String c) => c.codeUnits.every((u) => u < 0x80);
