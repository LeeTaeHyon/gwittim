# google_mlkit_text_recognition: 한국어 인식기만 쓴다(D-058). 쓰지 않는 중국어·일본어·데바나가리 인식기 클래스는 앱에 넣지 않으므로 R8 경고를 끈다.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
