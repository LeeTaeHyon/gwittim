import 'package:image_picker/image_picker.dart';

/// 앱 안에서 캡처 이미지를 고르는 창구 (D-061). 취소하면 null.
/// 시스템 사진 선택기를 쓰므로 저장소 권한이 필요 없다. 돌려주는 경로는 앱 캐시 사본이다.
abstract class ShareImagePicker {
  Future<String?> pick();
}

class GalleryShareImagePicker implements ShareImagePicker {
  @override
  Future<String?> pick() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    return file?.path;
  }
}
