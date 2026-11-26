import 'models.dart';
import 'repository.dart';

/// 카카오톡에서 넘긴 공고 (D-058, docs/kakao-manual-share-spec.md). 서버 API가 있는 저장소만 구현한다.
/// 본인만 보며, 공용 추천·저장·지원 건 기록에는 섞지 않는다.
abstract interface class SharedNoticeApi {
  /// 기기에서 가린 글을 보내 분석·저장한다. 개인 알림이라 서버가 거절하면 [SubmitSharedResult.item]이 null.
  /// 오류: consentRequired, rateLimited, invalidArgument, unavailable
  Future<SubmitSharedResult> submitShared({
    required String text,
    required ShareInput input,
    bool? ocrEdited,
  });

  /// 내가 넘긴 공고, 최근순
  Future<List<SharedNoticeItem>> listShared();

  /// 반복 요청 안전
  Future<void> deleteShared(String id);
}

class SubmitSharedResult {
  const SubmitSharedResult(this.item);

  /// 저장된 항목. 개인 알림·잡음이라 저장하지 않았으면 null
  final SharedNoticeItem? item;

  bool get personalNotice => item == null;
}

/// 감싼 저장소(캐시·지원 건 기록) 안쪽까지 찾아 넘기기 API를 돌려준다. 샘플 자료처럼 없으면 null.
SharedNoticeApi? sharedApiOf(NoticeRepository repository) {
  if (repository is SharedNoticeApi) return repository as SharedNoticeApi;
  if (repository case WrappingRepository(:final inner)) {
    return sharedApiOf(inner);
  }
  return null;
}
