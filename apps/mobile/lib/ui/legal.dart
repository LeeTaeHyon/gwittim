import 'package:flutter/material.dart';

import 'common.dart';

/// 체험판 이용약관·개인정보 처리방침 (D-030). 저장소가 비공개라 공개 구글 문서로 둔다.
/// 문서 원문은 docs/legal/에 있고, 고치면 구글 문서도 함께 고친다.
final termsUrl = Uri.parse('https://docs.google.com/document/d/TERMS_DOC_ID/view');
final privacyUrl = Uri.parse('https://docs.google.com/document/d/PRIVACY_DOC_ID/view');

/// 문서를 브라우저로 연다. 열지 못하면 짧게 알린다.
Future<void> openLegal(BuildContext context, OpenUrl openUrl, Uri url) async {
  final messenger = ScaffoldMessenger.of(context);
  if (await openUrl(url)) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(content: Text('문서를 열지 못했습니다.')));
}
