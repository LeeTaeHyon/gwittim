import 'dart:io';
import 'dart:ui' as ui;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'ocr_cleanup.dart';

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
      final lines = [
        for (final b in result.blocks)
          for (final l in b.lines)
            OcrLine(
              l.text,
              left: l.boundingBox.left,
              top: l.boundingBox.top,
              right: l.boundingBox.right,
              bottom: l.boundingBox.bottom,
              words: [
                for (final e in l.elements)
                  OcrWord(
                    e.text,
                    left: e.boundingBox.left,
                    top: e.boundingBox.top,
                    right: e.boundingBox.right,
                    bottom: e.boundingBox.bottom,
                    confidence: e.confidence,
                    symbols: [
                      for (final y in e.symbols)
                        OcrWord(
                          y.text,
                          left: y.boundingBox.left,
                          top: y.boundingBox.top,
                          right: y.boundingBox.right,
                          bottom: y.boundingBox.bottom,
                          confidence: y.confidence,
                        ),
                    ],
                  ),
              ],
            ),
      ];
      final cleaned = cleanOcrLines(lines, imageHeight: await _height(imagePath));
      // 정리가 거의 다 지웠다면 틀린 정리일 수 있어 원문을 그대로 쓴다(어차피 확인·수정 단계가 있다)
      return cleaned.trim().length < 20 ? result.text : cleaned;
    } finally {
      await recognizer.close();
    }
  }

  Future<double?> _height(String path) async {
    try {
      final codec = await ui.instantiateImageCodec(
        await File(path).readAsBytes(),
      );
      final frame = await codec.getNextFrame();
      final h = frame.image.height.toDouble();
      frame.image.dispose();
      codec.dispose();
      return h;
    } catch (_) {
      return null; // 크기를 모르면 위치로는 거르지 않는다
    }
  }
}
