import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:collection/collection.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:omi/utils/logger.dart';
import 'package:omi/utils/platform/keep_screen_on.dart';

typedef ChestPhotoHandler = void Function(Uint8List jpegBytes);

/// Chest-mounted periodic photo capture.
///
/// The phone in a chest pocket replaces what a camera-capable wearable
/// (Ray-Ban Meta, OpenGlass) would otherwise provide: while a live capture
/// session runs, one silent JPEG every [interval] flows into the session's
/// existing photo path (placeholder -> base64 WebSocket chunks -> backend
/// `describe_image`), so the conversation gets AI scene descriptions exactly
/// like glasses photos do.
///
/// Capture stays foreground-bound: both platforms stop camera access once the
/// screen locks, so the screen is kept on for the service's lifetime and the
/// phone's display timeout is defeated while a chest session runs. Locked-screen
/// capture on Android would need a native camera foreground service
/// (CameraX inside FOREGROUND_SERVICE_CAMERA); iOS forbids background camera
/// use outright, so V1 does not attempt either.
class ChestCameraService {
  ChestCameraService({
    this.interval = const Duration(seconds: 30),
    this.ensurePermission = _requestCameraPermission,
    this.listCameras = availableCameras,
    this.keepScreenOn = KeepScreenOn.set,
  });

  /// Mirrors RayBanMetaDeviceConnection.autoCaptureInterval: the glasses' capture cadence.
  final Duration interval;

  /// Test seams; production leaves the defaults.
  final Future<bool> Function() ensurePermission;
  final Future<List<CameraDescription>> Function() listCameras;
  final Future<void> Function(bool) keepScreenOn;

  CameraDescription? _description;
  CameraController? _controller;
  Timer? _timer;
  bool _capturing = false;
  bool _stopping = false;

  bool get isRunning => _timer != null;

  static Future<bool> _requestCameraPermission() async => (await Permission.camera.request()).isGranted;

  /// Opens the rear camera and starts periodic capture. Returns false — and
  /// stays stopped — when the permission is denied or no camera exists, so the
  /// caller surfaces that once instead of on every tick.
  Future<bool> start({required ChestPhotoHandler onPhoto}) async {
    if (_timer != null) return true;
    if (!await ensurePermission()) {
      Logger.debug('ChestCamera: camera permission denied');
      return false;
    }
    final cameras = await listCameras();
    final description = cameras.firstWhereOrNull((c) => c.lensDirection == CameraLensDirection.back) ??
        cameras.firstOrNull;
    if (description == null) {
      Logger.debug('ChestCamera: no camera available');
      return false;
    }
    _description = description;
    final controller = await _open(description);
    if (controller == null) return false;
    _controller = controller;
    // The phone sits unattended in a pocket: without this the screen sleeps and
    // both platforms close the camera, ending every future tick.
    await keepScreenOn(true);
    _timer = Timer.periodic(interval, (_) => _captureTick(onPhoto));
    return true;
  }

  /// One tick: capture if the camera is open, reopen it if the plugin released
  /// it (app pause/lock screen), and never let an in-flight capture re-enter.
  Future<void> _captureTick(ChestPhotoHandler onPhoto) async {
    if (_capturing || _stopping) return;
    _capturing = true;
    try {
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) {
        await _reopen();
        return;
      }
      final file = await controller.takePicture();
      try {
        final bytes = await file.readAsBytes();
        if (!_stopping && bytes.isNotEmpty) onPhoto(bytes);
      } finally {
        // takePicture writes into the app cache; one file per tick must not
        // accumulate over a multi-hour session.
        unawaited(_deleteQuietly(file.path));
      }
    } catch (e) {
      // A missed frame never ends the session; the next tick reopens if closed.
      Logger.debug('ChestCamera: capture failed: ${e.runtimeType}');
      unawaited(_reopenIfClosed());
    } finally {
      _capturing = false;
    }
  }

  Future<void> _reopenIfClosed() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) await _reopen();
  }

  Future<CameraController?> _open(CameraDescription description) async {
    // Medium (roughly 480p) is what AI scene description needs; each photo is
    // base64-chunked over the transcription socket, so resolution is bandwidth.
    final controller = CameraController(description, ResolutionPreset.medium);
    try {
      await controller.initialize();
      return controller;
    } catch (e) {
      Logger.debug('ChestCamera: open failed: ${e.runtimeType}');
      try {
        await controller.dispose();
      } catch (_) {}
      return null;
    }
  }

  Future<void> _reopen() async {
    if (_stopping) return;
    final description = _description;
    if (description == null) return;
    final old = _controller;
    _controller = null;
    try {
      await old?.dispose();
    } catch (_) {}
    final controller = await _open(description);
    if (controller != null) _controller = controller;
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  Future<void> stop() async {
    _stopping = true;
    _timer?.cancel();
    _timer = null;
    final controller = _controller;
    _controller = null;
    try {
      await controller?.dispose();
    } catch (_) {}
    await keepScreenOn(false);
    _stopping = false;
  }
}
