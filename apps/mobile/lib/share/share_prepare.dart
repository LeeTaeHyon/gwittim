import '../classifier/kakao_filter.dart';

/// 서버 요청 글자 수 한도 (shared_notice_request.text). 계약과 같다.
const shareTextMin = 20;
const shareTextMax = 5000;

/// 카톡에서 넘긴 글을 보내기 전에 기기에서 손보는 결과 (D-058, docs/kakao-manual-share-spec.md §3).
/// 서버도 같은 규칙으로 한 번 더 가린다.
class SharePrep {
  const SharePrep({
    required this.cleaned,
    required this.kind,
    required this.masked,
  });

  /// 자동응답 문구·빈 템플릿 칸을 뺀 글 (cleanBody)
  final String cleaned;

  /// 알림톡 종류 (kakaoKind)
  final String kind;

  /// 학번·휴대폰·교수·받는 사람 이름을 가린 글 (maskPersonal). 서버로 가는 글이다.
  final String masked;

  /// 개인 알림·잡음이라 분석·저장하지 않는 글. 참여 학생 대상 안내(participant)는 본인이 받은 글이라 분석한다.
  bool get isPersonal =>
      kind == KakaoKind.personalCourse ||
      kind == KakaoKind.personalAccount ||
      kind == KakaoKind.noise;

  /// 가린 부분 개수
  int get maskedCount => maskTokens.allMatches(masked).length;

  bool get tooShort => masked.trim().runes.length < shareTextMin;
  bool get tooLong => masked.runes.length > shareTextMax;

  /// 보낼 수 있는 글인지 (개인 알림 아님, 길이 범위 안)
  bool get sendable => !isPersonal && !tooShort && !tooLong;
}

/// 가린 자리 표시 (<학번>, <휴대폰>, <교수>, <이름>)
final RegExp maskTokens = RegExp('<(학번|휴대폰|교수|이름)>');

/// 확인 화면용: 글 한 편에서 받는 사람 이름을 찾고(두 번 이상 나온 '○○○님') 개인정보를 가린다.
SharePrep prepareShare(String raw) {
  final cleaned = cleanBody(raw);
  final names = detectNames([cleaned]);
  final kind = kakaoKind(cleaned, names);
  return SharePrep(
    cleaned: cleaned,
    kind: kind,
    masked: maskPersonal(cleaned, names),
  );
}
