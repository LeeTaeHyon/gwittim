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
- 날짜만 확인된 마감은 시각 없이 표시합니다. 시각이 있는데 시간대가 미상이면 "(시간대 미확인)"을 붙입니다.
