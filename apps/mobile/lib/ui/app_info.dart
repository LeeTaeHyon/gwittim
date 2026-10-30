import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 내 정보 > 설정 > 앱 정보에 보이는 버전. pubspec.yaml의 version(빌드 번호 앞)과 같아야 하고,
/// 테스트가 둘이 같은지 확인한다. 버전을 올리면 두 곳을 함께 고친다.
const appVersion = '1.0.0';

/// 앱에 직접 넣은 글꼴의 라이선스를 오픈소스 라이선스 화면에 등록한다.
/// 패키지 라이선스는 Flutter가 자동으로 모으지만, assets/fonts의 글꼴은 직접 등록해야 한다.
void registerAppLicenses() {
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/fonts/Pretendard-LICENSE.txt');
    // Windows 체크아웃에서는 CRLF가 되는데, \r이 남으면 빈 네모 글자로 보인다.
    yield LicenseEntryWithLineBreaks(const ['Pretendard'], text.replaceAll('\r\n', '\n'));
  });
}
