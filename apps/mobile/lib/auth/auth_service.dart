import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// 로그인 경계. 앱은 사용자 ID를 서버에 보내지 않고, 이 서비스가 주는 ID 토큰만 보낸다 (SPEC §5).
abstract class AuthService {
  /// 로그인 상태 변화. true = 로그인됨.
  Stream<bool> get signedIn;

  /// 서버 API에 보낼 Firebase ID 토큰. 로그인 전이면 null. [refresh]이면 받아 둔 토큰 대신 새로 받는다.
  Future<String?> idToken({bool refresh = false});

  /// 사용자가 취소하면 false.
  Future<bool> signInWithGoogle();

  /// 로그인 없이 둘러보기 (D-054). Firebase 익명 계정을 만든다. 실패하면 예외.
  Future<void> signInAsGuest();

  /// 지금 로그인한 계정이 게스트(익명 계정)인지. 로그인 전이면 false.
  bool get isGuest;

  /// 로그인 계정의 표시 이름('OO님 기준' 표시용, 기기 안에서만 쓴다). 게스트·모르면 null.
  String? get displayName;

  Future<void> signOut();

  /// 탈퇴 (D-024). 계정을 다시 확인한 뒤 [deleteData]로 서버 데이터를 지우고 로그인 계정을 지운다.
  /// 다시 확인을 취소하면 아무것도 지우지 않고 false.
  /// 게스트는 다시 확인 없이 서버 데이터 → 익명 계정 순서로 지운다('게스트 끝내기', D-054).
  Future<bool> deleteAccount(Future<void> Function() deleteData);
}

/// Firebase Authentication + Google 로그인 (D-004). Android 설정은 android/app/google-services.json(커밋 금지).
class FirebaseAuthService implements AuthService {
  FirebaseAuthService({FirebaseAuth? auth, GoogleSignIn? google})
    : _auth = auth ?? FirebaseAuth.instance,
      _google = google ?? GoogleSignIn.instance;

  final FirebaseAuth _auth;
  final GoogleSignIn _google;

  /// main()에서 한 번 부른다. serverClientId는 google-services.json의 웹 클라이언트를 플러그인이 읽는다.
  static Future<void> initializeGoogle() => GoogleSignIn.instance.initialize();

  @override
  Stream<bool> get signedIn => _auth.authStateChanges().map((user) => user != null);

  @override
  Future<String?> idToken({bool refresh = false}) async => _auth.currentUser?.getIdToken(refresh);

  @override
  bool get isGuest => _auth.currentUser?.isAnonymous ?? false;

  @override
  String? get displayName => isGuest ? null : _auth.currentUser?.displayName;

  @override
  Future<void> signInAsGuest() async {
    await _auth.signInAnonymously();
  }

  @override
  Future<bool> signInWithGoogle() async {
    try {
      final account = await _google.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) return false;
      await _auth.signInWithCredential(GoogleAuthProvider.credential(idToken: idToken));
      return true;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return false;
      rethrow;
    }
  }

  /// Firebase 계정 삭제는 최근 로그인을 요구해서, 지우기 전에 같은 Google 계정으로 다시 확인받는다.
  /// 다른 계정을 고르면 Firebase가 거절해 아무것도 지우지 않는다.
  @override
  Future<bool> deleteAccount(Future<void> Function() deleteData) async {
    final user = _auth.currentUser;
    if (user == null) return false;
    if (user.isAnonymous) {
      // 익명 계정은 다시 확인할 수단이 없다. 서버 삭제가 실패하면 계정은 남겨 다시 누를 수 있게 한다.
      await deleteData();
      await user.delete();
      return true;
    }
    final GoogleSignInAccount account;
    try {
      account = await _google.authenticate();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return false;
      rethrow;
    }
    final idToken = account.authentication.idToken;
    if (idToken == null) return false;
    await user.reauthenticateWithCredential(GoogleAuthProvider.credential(idToken: idToken));
    await deleteData();
    // 여기서 실패하면 데이터만 지워진 채 로그인 상태로 남는다. 서버 삭제는 반복 요청 안전이라 다시 누르면 된다.
    await user.delete();
    await _google.signOut();
    return true;
  }

  @override
  Future<void> signOut() async {
    await _google.signOut();
    await _auth.signOut();
  }
}

/// 로컬 개발 서버용 게스트 시험 (GWITTIM_DEV_GUEST). Firebase 없이 로그인 화면 → 게스트 → 게스트 끝내기를 돈다.
/// 토큰은 backend.api.local의 게스트 토큰(guest-token)을 그대로 쓴다. Google 로그인은 하지 않는다.
class LocalGuestAuthService implements AuthService {
  LocalGuestAuthService(this._token);

  final String _token;
  final _state = StreamController<bool>.broadcast();
  bool _signedIn = false;

  @override
  Stream<bool> get signedIn async* {
    yield _signedIn;
    yield* _state.stream;
  }

  @override
  bool get isGuest => _signedIn;

  @override
  String? get displayName => null;

  @override
  Future<String?> idToken({bool refresh = false}) async => _signedIn ? _token : null;

  @override
  Future<void> signInAsGuest() async => _set(true);

  @override
  Future<bool> signInWithGoogle() async => false;

  @override
  Future<bool> deleteAccount(Future<void> Function() deleteData) async {
    await deleteData();
    _set(false);
    return true;
  }

  @override
  Future<void> signOut() async => _set(false);

  void _set(bool value) {
    _signedIn = value;
    _state.add(value);
  }
}
