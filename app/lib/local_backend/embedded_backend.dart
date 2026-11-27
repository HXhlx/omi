import 'package:flutter_backend/embedded.dart';
import 'package:path_provider/path_provider.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/env/env.dart';
import 'package:omi/local_backend/on_device_surfaces.dart';
import 'package:omi/services/auth/auth_token_result.dart';
import 'package:omi/services/auth_service.dart';

/// Build-time switch for the single-app local deployment.
///
/// Off by default, so upstream builds and every test keep pointing at the
/// configured (remote, or `adb reverse`d) backend. The 小蜗 on-phone build turns
/// it on with `--dart-define=OMI_EMBEDDED_BACKEND=true` and then needs no
/// second process, no `adb reverse`, and no PC on the wire.
const bool kEmbeddedLocalBackend = bool.fromEnvironment('OMI_EMBEDDED_BACKEND');

/// Runs the Dart local backend (`tools/flutter_backend`) inside this app's own
/// process, on an OS-chosen loopback port, and points [Env] at it.
///
/// Call before `ServiceManager.init()`: that snapshots the base URL for its
/// health probes, so an override installed afterwards would be ignored.
class EmbeddedLocalBackend {
  EmbeddedLocalBackend._();

  static LocalBackendServer? _server;
  static String? _baseUrl;

  /// Base URL the embedded server is reachable at, or null if it never bound.
  static String? get baseUrl => _baseUrl;

  /// Idempotent: a hot restart re-runs `_init` with the process still alive.
  static Future<String?> start() async {
    if (_server != null) return _baseUrl;

    // The local backend is a fake root of trust, not a signed-in user: mint a
    // synthetic session so [AuthService.isSignedIn] and every authenticated
    // HTTP client resolve before the first request, with no Auth emulator, no
    // network, and no account lifecycle on the wire.
    //
    // Unconditional in the embedded build. A previously-installed session can
    // leave a persisted Firebase user behind (an emulator-minted one from an
    // earlier harness run); gating on "no current Firebase user" then skips
    // the gateway, every token refresh dials real Firebase, times out after
    // 8s, and the home feed dies behind an error screen even though the
    // in-process backend is serving 200s.
    SharedPreferencesUtil().uid = kLocalDevUid;
    SharedPreferencesUtil().authToken = kLocalDevUid; // opaque Bearer, embeds the uid
    SharedPreferencesUtil().tokenExpirationTime = DateTime.now().millisecondsSinceEpoch;
    AuthService.installLocalHarnessTokenGateway(_StaticTokenGateway());

    final support = await getApplicationSupportDirectory();
    // On-device inference: the local-stt / local-tts provider cards run
    // whisper.cpp and the system speech engine in this process. A missing
    // whisper model only fails those cards' calls (503 with a clear message),
    // never the backend itself.
    OnDeviceInferenceSurfaces? onDevice;
    try {
      onDevice = await OnDeviceInferenceSurfaces.create();
    } catch (_) {}
    final server = await LocalBackendServer.start(
      dbPath: '${support.path}/omi_local.db',
      localStt: onDevice?.sttByCard,
      localTts: onDevice?.tts,
      localEmbed: onDevice?.embed,
    );

    _server = server;
    // Trailing slash: the app concatenates paths onto this directly.
    _baseUrl = '${server.uri}/';
    Env.overrideApiBaseUrl(_baseUrl!);
    return _baseUrl;
  }

  static const String kLocalDevUid = 'local-dev-user';

  static Future<void> stop() async {
    final server = _server;
    _server = null;
    _baseUrl = null;
    await server?.close();
  }
}

/// A session that exists only because the local backend is the whole server.
///
/// Firebase is not reachable in a fully on-device build, so every authenticated
/// request would otherwise fail at the token step. The backend ignores the
/// credential entirely (one local user), so a fixed opaque Bearer is enough:
/// callers keep their real refresh/expiry logic and just always succeed.
final class _StaticTokenGateway implements AuthTokenGateway {
  @override
  AuthUserSnapshot? get currentUser =>
      const AuthUserSnapshot(uid: EmbeddedLocalBackend.kLocalDevUid, isAnonymous: false);

  @override
  Future<RefreshedAuthToken?> forceRefresh() async => RefreshedAuthToken(
        token: EmbeddedLocalBackend.kLocalDevUid,
        expirationTime: DateTime.now().add(const Duration(days: 1)),
      );

  @override
  Future<void> signOut() async {}
}