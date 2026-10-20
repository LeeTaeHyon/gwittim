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
  'not_met' => '지원 조건 불충족',
  _ => '조건 확인 필요',
};

/// reason_codes 공통 템플릿 (SPEC §5·§6). '관심 분야 관련'과 '지원 조건 충족'을 구분한다.
String reasonText(String code) => switch (code) {
  'interest_match' => '관심 분야와 관련된 공고예요',
  'role_match' => '희망 직무와 관련된 공고예요',
  'major_match' => '전공과 관련된 공고예요',
  'deadline_timing' => '2주 안에 신청이 마감돼요',
  'eligibility_met' => '확인된 지원 조건을 모두 충족해요',
  'eligibility_needs_check' => '지원 조건을 원문에서 확인해 주세요',
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
  if (lastVerifiedAt == null) return '원문 확인 시각을 알 수 없어요. 지원 전에 원문을 확인해 주세요.';
  final hours = now.difference(lastVerifiedAt).inHours;
  if (hours < 24) return null;
  final ago = hours < 48 ? '$hours시간' : '${hours ~/ 24}일';
  return '마지막 확인 $ago 전이에요. 내용이 바뀌었을 수 있어요.';
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
  'not_met' => '조건 불충족',
  _ => '조건 확인 필요',
};

/// 개인화 추천 이유 코드 → 화면 낱말 (형광펜으로 강조)
const personalReasons = {'interest_match': '관심 분야', 'role_match': '희망 직무', 'major_match': '전공'};
