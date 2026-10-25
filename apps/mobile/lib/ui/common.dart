import 'package:flutter/material.dart';

import '../data/repository.dart';
import 'components.dart';
import 'logo.dart';
import 'theme.dart';

/// 원문 열기 (url_launcher). 테스트에서는 바꿔 끼운다.
typedef OpenUrl = Future<bool> Function(Uri url);

/// 사용자에게는 상세 오류·스택을 보여주지 않는다 (SPEC §9·§10).
String errorMessage(Object error) {
  if (error is RepositoryException) {
    return switch (error.kind) {
      RepositoryErrorKind.unauthenticated => '다시 로그인해 주세요.',
      RepositoryErrorKind.permissionDenied => '볼 수 있는 권한이 없어요.',
      RepositoryErrorKind.notFound => '공고를 찾을 수 없어요.',
      _ => '잠시 후 다시 시도해 주세요.',
    };
  }
  return '잠시 후 다시 시도해 주세요.';
}

/// 이미 보이는 목록을 새로 받지 못했을 때. 목록은 그대로 두고 짧게 알린다.
void showRefreshFailed(BuildContext context, Object error) {
  final unavailable = error is! RepositoryException || error.kind == RepositoryErrorKind.unavailable;
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(unavailable ? '새로 불러오지 못했어요. 인터넷 연결을 확인해 주세요.' : errorMessage(error))));
}

/// 빈 화면의 오류·안내. 글자 없는 로고 말풍선 그림, 한 줄 제목, 한 줄 설명, 앱 버튼.
class MessageView extends StatelessWidget {
  const MessageView({super.key, required this.title, this.detail, this.onRetry, this.action});

  final String title;
  final String? detail;
  final VoidCallback? onRetry;

  /// 다시 시도 대신 다음 행동 버튼 ('공고 둘러보기' 등)
  final ({String label, VoidCallback onPressed})? action;

  /// 불러오기 실패. 상세 오류는 보이지 않고 errorMessage 문구만 보인다.
  factory MessageView.error(Object error, {Key? key, VoidCallback? onRetry}) =>
      MessageView(key: key, title: '불러오지 못했어요', detail: errorMessage(error), onRetry: onRetry);

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 라이트의 neutral은 화면 바탕과 같은 색이라, 바탕과 카드 어디서나 보이는 line으로 칠한다.
            ExcludeSemantics(child: GwBubbleMark(height: 44, color: c.line)),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, height: 1.45, fontWeight: FontWeight.w600, color: c.ink),
            ),
            if (detail != null) ...[
              const SizedBox(height: 4),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, height: 1.5, color: c.sub),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 18),
              SoftButton(label: '다시 시도', icon: null, onPressed: onRetry!),
            ] else if (action case final a?) ...[
              const SizedBox(height: 18),
              SoftButton(label: a.label, onPressed: a.onPressed),
            ],
          ],
        ),
      ),
    );
  }
}
