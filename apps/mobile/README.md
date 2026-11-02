# 귀띔 Android 앱 (apps/mobile)

Flutter 3.47.7 / Dart 3.13.5 (D-004). 지금은 합성 샘플 자료로 동작하는 피드·상세·원문 열기까지 구현되어 있습니다(W5).

```bash
cd apps/mobile
flutter pub get
flutter analyze
flutter test
flutter run            # 에뮬레이터 또는 실기기
```

- 데이터 접근은 `lib/data/repository.dart`의 `NoticeRepository`로만 합니다. `SampleNoticeRepository`(지금)와 실제 구현(W6: Firebase 로그인·Firestore·서버 API)을 교체합니다.
- 샘플 자료 `assets/sample/`는 `uv run python -m tools.export_mobile_sample`로 fixtures에서 만듭니다. 추천 순서·이유는 백엔드 추천 함수 출력 그대로이며, 앱은 점수를 계산하지 않습니다.
- `flutter run`(샘플 모드)은 샘플 날짜를 오늘 기준으로 옮겨 보여 줍니다. 10월 30일을 오늘로 만든 자료라 언제 켜도 발표회가 오늘 마감, 경진대회가 D-3입니다. 테스트는 원래 날짜를 씁니다.
- 날짜만 확인된 마감은 시각 없이 표시합니다. 시각이 있는데 시간대가 미상이면 "(시간대 미확인)"을 붙입니다.

## 서버 API로 실행

```bash
# 저장소 루트에서 로컬 API (합성 공고, 개발용 토큰)
uv run uvicorn backend.api.local:app --port 8765
# 앱 (Android 에뮬레이터에서는 10.0.2.2가 PC의 localhost)
flutter run --dart-define=GWITTIM_API_BASE=http://10.0.2.2:8765/ --dart-define=GWITTIM_DEV_TOKEN=dev-token
# 앱 ↔ 서버 계약 테스트
GWITTIM_LIVE_API=http://127.0.0.1:8765/ flutter test test/api_live_test.dart
```

`GWITTIM_API_BASE`를 비우면 합성 샘플로 동작합니다. 이때 화면 왼쪽 위에 '샘플 자료' 띠가, 개발용 토큰으로 로컬 API를 부를 때는 '로컬 서버' 띠가 붙습니다. dev 서버로 도는 빌드에는 띠가 없습니다. 실제 로그인(Firebase Auth ID 토큰)은 Firebase 프로젝트 생성 후 `tokenProvider`만 바꿉니다.

## dev 서버 + Google 로그인으로 실행 (gwittim-dev)

1. Firebase 콘솔에서 받은 `google-services.json`을 `android/app/`에 둡니다(커밋 금지, `.gitignore` 처리됨).
2. 실행:

```bash
flutter run --dart-define=GWITTIM_API_BASE=https://gwittim-api-630835219636.asia-northeast3.run.app/
```

- 로그인 화면 → Google 로그인 → Firebase ID 토큰으로 서버 API를 부릅니다. 앱은 사용자 ID를 보내지 않습니다.
- Google 로그인은 Firebase에 등록된 SHA-1의 키로 서명된 빌드에서만 됩니다(지금은 이 PC의 디버그 키).
- `GWITTIM_DEV_TOKEN`을 함께 주면 로그인 없이 로컬 개발 서버용 토큰을 씁니다.
