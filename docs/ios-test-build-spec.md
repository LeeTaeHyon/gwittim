# iOS 테스트 빌드·시연 준비 명세

- 작성: 2026-11-26 (11/26 멘토링 과제 "iOS 테스트 환경 확보", 12/3 미팅 전 확인 목표)
- 상태: §2 결정 5개 추천안대로 확정(팀장, 2026-11-26), 구현 전
- 장비: 맥북 프로 15인치 2018(인텔, macOS 15.7.3), 아이폰 SE 2세대(iOS 18.7.8)
- 결론: 실습실·맥 클라우드 없이 이 장비로 가능. 폰 OS는 올릴 필요 없음
- 작업 위치: 맥에서 저장소를 새로 받아 브랜치 `feat/ios-demo-build`
- 커밋·PR·Firebase 변경은 팀장 지시 뒤에. Firebase iOS 앱 등록은 팀장이 콘솔에서 직접

## 1. 범위

- 한다
  - `apps/mobile`에 iOS 폴더 생성, 아이폰 SE 2세대 실기기 설치
  - 샘플 모드 → 실서버 게스트 로그인 → (선택) Google 로그인 순서로 확인
  - 시연용 화면 녹화 방법 정리
- 하지 않는다
  - App Store·TestFlight 배포, 유료 개발자 계정 가입
  - iOS 전용 기능·화면 추가, 푸시 알림
  - 알림톡 자동 수집(안드로이드 팀장 폰 한 대, D-034) — iOS에는 해당 없음
  - Android 쪽 코드·설정 변경

## 2. 팀장 결정 (2026-11-26, 추천안대로 확정)

| # | 결정할 것 | 확정 내용 | 이유 |
|---|---|---|---|
| 1 | SPEC P0 제외 목록의 "iOS" 처리 | "iOS는 시연용 빌드만, 스토어 배포 제외"로 좁혀 기록 | 지금은 iOS 전체가 제외라 폴더 생성도 범위 밖. AGENTS §3 절차(SPEC + decisions.md 같은 PR) |
| 2 | Firebase에 iOS 앱 등록 | 등록 (기존 프로젝트에 앱만 추가, 무료) | 실서버 로그인에 `GoogleService-Info.plist` 필요. 단계 A는 없이도 됨 |
| 3 | 번들 ID | `kr.gwittim.gwittim` (Android와 같게) | Firebase 등록 한 번으로 끝. 무료 계정 팀에 묶이므로 서명 Apple ID는 팀장 것으로 |
| 4 | Google 로그인까지 할지 | 12/3까지는 게스트 로그인만, Google은 뒤에 | 게스트는 추가 설정 없음. Google은 iOS 클라이언트·URL 스킴 설정 필요 |
| 5 | 서명 계정 | 무료 Apple ID | 비용 0원. 7일마다 재설치 필요. 유료는 연 약 14만 원(99달러) |

## 3. 맥 환경 준비 (사람, 1회)

- Xcode
  - macOS 15.7.3에 설치되는 Xcode 26.x. App Store가 더 높은 macOS를 요구하면 developer.apple.com/download에서 "macOS 15.6 이상"으로 표기된 26.x를 받는다
  - 설치 뒤 한 번 실행해 iOS 구성 요소 설치, 라이선스 동의
  - 저장 공간 여유 40GB 이상 권장
- Flutter
  - `pubspec.lock` 기준 Flutter 3.44.0 이상, Dart 3.13.5 이상. Windows 개발 PC와 같은 버전으로 맞춘다
  - 인텔 맥(x64)용 설치본 사용
- CocoaPods: `flutter doctor`가 요구하면 설치 (Homebrew 또는 gem)
- 확인: `flutter doctor -v`에서 Xcode·iOS 항목 통과
- 아이폰
  - 케이블 연결 → "이 컴퓨터를 신뢰"
  - 설정 > 개인정보 보호 및 보안 > 개발자 모드 켜기(재시동). 메뉴가 안 보이면 Xcode에 한 번 연결한 뒤 다시 확인
  - Xcode > Settings > Accounts에 Apple ID 추가

## 4. 작업 단계

### 단계 A — 샘플 모드로 실기기 실행 (결정 1만 있으면 가능)

1. `apps/mobile`에서 `flutter create --platforms=ios .`
   - 기존 파일을 덮어쓰지 않는지 `git status`로 확인. `ios/` 밖의 변경이 생기면 되돌린다
2. `ios/Runner.xcworkspace`를 Xcode로 열어 Runner > Signing & Capabilities
   - Team: 팀장 Apple ID(Personal Team), Bundle Identifier: 결정 3의 값
3. 표시 이름을 "귀띔"으로 (`Info.plist`의 `CFBundleDisplayName`)
4. `flutter run` (dart-define 없음 = 샘플 모드, Firebase 불필요)
5. 첫 실행 때 폰에서 설정 > 일반 > VPN 및 기기 관리 > 개발자 앱 신뢰
- 완료 기준: SE 2세대에서 인트로 → 홈 목록 → 상세까지 열림, 왼쪽 위 자료 띠 표시

### 단계 B — 실서버 + 게스트 로그인 (결정 2 뒤)

1. 팀장: Firebase 콘솔에서 iOS 앱 추가(번들 ID 동일) → `GoogleService-Info.plist` 내려받기
2. Xcode에서 Runner 대상에 파일 추가 (`ios/Runner/`, "Copy items" 체크)
3. `.gitignore`에 `GoogleService-Info.plist` 추가 — 커밋 금지(AGENTS §4)
4. 빌드 중 최소 iOS 버전 오류가 나면 Podfile·프로젝트의 배포 대상을 오류가 요구하는 값으로 올린다 (SE 2세대는 iOS 18이라 영향 없음)
5. 실행

   ```
   flutter run --release --dart-define=GWITTIM_API_BASE=https://gwittim-api-630835219636.asia-northeast3.run.app --dart-define=GWITTIM_DEMO=true
   ```

- 완료 기준: 게스트로 시작 → 실제 공고 목록 → 상세 → 원문 링크 열기(사파리) → 게스트 끝내기
- 상세 분석·외부 공고 찾기는 비용이 드니 시연 때 1건만

### 단계 C — Google 로그인 (결정 4에서 하기로 하면)

1. `GoogleService-Info.plist`의 `REVERSED_CLIENT_ID`를 `Info.plist` URL 스킴에 추가
2. `Info.plist`에 `GIDClientID`(iOS 클라이언트), `GIDServerClientID`(웹 클라이언트) 추가
   - Android는 `google-services.json`에서 플러그인이 읽지만 iOS는 직접 적어야 함 (`lib/auth/auth_service.dart:40` 주석 참고)
3. 무료 계정으로 Google 로그인이 막히면 여기서 멈추고 보고
- 완료 기준: Google 계정 로그인 → 프로필 → 로그아웃 → 탈퇴(시험 계정)

### 단계 D — 화면 점검·시연 준비

- SE 2세대는 4.7인치(375×667pt)로 우리 기준 화면보다 작다. 점검할 것
  - 넘침(노란·검은 줄), 잘린 글자, 하단 버튼이 홈 버튼 영역과 겹치는지
  - 다크 모드, 글자 크게 설정
  - 뒤로 가기: 화면 왼쪽 끝 쓸어넘기기 동작
  - 한글 입력, 키보드가 입력칸을 가리는지
- 고칠 화면이 나오면 목록만 만들고 수정은 별도 작업으로 (docs/ui-style.md 기준)
- 녹화: 아이폰 제어 센터 화면 기록, 또는 케이블 연결 후 맥 QuickTime > 새로운 동영상 녹화 > 카메라를 아이폰으로
- 무료 계정은 설치 후 7일이면 실행이 막힘 → 시연 전날 다시 설치

## 5. 커밋 대상

- 커밋: `apps/mobile/ios/` (생성된 프로젝트), `.gitignore`, `apps/mobile/README.md`에 iOS 실행 방법 몇 줄
- 커밋 금지: `GoogleService-Info.plist`, 인증서·프로비저닝 파일
- 서명 팀 ID(`DEVELOPMENT_TEAM`)가 `project.pbxproj`에 들어가면 커밋 전에 뺀다
- 결정 1이 나면 같은 PR에 SPEC.md P0 제외 문구, `docs/decisions.md` 새 번호

## 6. 검증

- `flutter analyze` 0, `flutter test` 전부 통과 (맥에서)
- Android 빌드가 그대로 되는지 Windows에서 `flutter build apk` 1회
- 단계 A·B(·C) 완료 기준을 실기기에서 확인한 결과와 캡처
- 실행 못 한 것은 "미실행"과 사유

## 7. 위험

| 위험 | 대응 |
|---|---|
| Flutter 3.44가 인텔 맥 또는 이 Xcode 버전을 지원하지 않음 (미확인) | §3 `flutter doctor`에서 먼저 확인. 막히면 그때 실습실·맥 클라우드 검토 |
| Firebase iOS SDK가 요구하는 최소 Xcode가 더 높음 (미확인) | 단계 B 빌드 오류로 드러남. 단계 A까지만 시연하고 보고 |
| 무료 계정 7일 만료, 기기당 앱 3개 제한 | 시연 전날 재설치 |
| 인텔 맥 첫 빌드 느림(수 분~10분대) | 시연 당일 빌드 금지, 미리 설치 |
| 아이폰을 iOS 26 이상으로 올리면 Xcode 버전과 어긋날 수 있음 | 시연 끝날 때까지 18.7.x 유지, 자동 업데이트 끄기 |
| 내년 이후 스토어 제출은 더 새 Xcode 필요 | 이번 범위 밖. 배포를 정하면 그때 장비 재검토 |

## 8. 보고

- AGENTS §5 형식: 변경 파일, 실행한 검증과 결과, 남은 문제, 다음 제안
- 상태가 바뀌면 `docs/handoff.md` 갱신
