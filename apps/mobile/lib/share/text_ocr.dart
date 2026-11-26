import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// 캡처 이미지의 글자 인식. 기기 안에서만 돌고 이미지는 서버로 보내지 않는다 (D-058).
/// 인식 글자는 틀릴 수 있어 사용자가 확인·수정한 뒤에만 보낸다 (D-014).
abstract class TextOcr {
  Future<String> recognize(String imagePath);
}

/// Google ML Kit 글자 인식(한국어, 기기 안 처리)
class MlkitTextOcr implements TextOcr {
  @override
  Future<String> recognize(String imagePath) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.korean);
    try {
      final result = await recognizer.processImage(
        InputImage.fromFilePath(imagePath),
      );
      return result.text;
    } finally {
      await recognizer.close();
    }
  }
}
