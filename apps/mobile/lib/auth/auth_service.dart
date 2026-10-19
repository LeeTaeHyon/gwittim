import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// 로그인 경계. 앱은 사용자 ID를 서버에 보내지 않고, 이 서비스가 주는 ID 토큰만 보낸다 (SPEC §5).
abstract class AuthService {
  /// 로그인 상태 변화. true = 로그인됨.
  Stream<bool> get signedIn;

  /// 서버 API에 보낼 Firebase ID 토큰. 로그인 전이면 null.
  Future<String?> idToken();

  /// 사용자가 취소하면 false.
  Future<bool> signInWithGoogle();

  Future<void> signOut();
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
  Future<String?> idToken() async => _auth.currentUser?.getIdToken();

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

  @override
  Future<void> signOut() async {
    await _google.signOut();
    await _auth.signOut();
  }
}
