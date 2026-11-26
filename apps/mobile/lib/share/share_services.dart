import 'share_inbox.dart';
import 'text_ocr.dart';

/// 카카오톡 공고 넘기기에 필요한 것들 (D-058). 없으면(샘플 자료 등) 공유 받기·붙여넣기 진입이 보이지 않는다.
class ShareServices {
  ShareServices({required this.inbox, TextOcr? ocr, ShareConsentStore? consent})
    : ocr = ocr ?? MlkitTextOcr(),
      consent = consent ?? PrefsShareConsentStore();

  final ShareInbox inbox;
  final TextOcr ocr;
  final ShareConsentStore consent;
}
