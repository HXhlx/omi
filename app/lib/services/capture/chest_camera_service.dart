import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:collection/collection.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:omi/utils/logger.dart';
import 'package:omi/utils/platform/keep_screen_on.dart';

/// One captured still or a keyframe of a recorded segment.
/// [kind] labels the source so the ingest path and the UI can render
/// "photo" vs "recorded segment" honestly.
class ChestCapture {
  ChestCapture({required this.kind, required this.jpegBytes, required this.capturedAt});

  /// `photo` (still tick) or `segment` (keyframe of a recorded clip).
  final String kind;
  final Uint8List jpegBytes;
  final DateTime capturedAt;
}

typedef ChestPhotoHandler = void Function(ChestCapture capture);

/// What a chest-camera tick produces.
enum ChestCameraMode {
  /// One still per tick (the glasses' cadence).
  photo,

  /// One recorded clip per tick: the camera records [interval] seconds, the
  /// clip's first frame is sent as the segment keyframe photo (same describe
  /// pipeline), and the clip's own bytes are handed to [onClip] for storage.
  video,
}

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
    this.mode = ChestCameraMode.photo,
    this.ensurePermission = _requestCameraPermission,
    this.listCameras = availableCameras,
    this.keepScreenOn = KeepScreenOn.set,
  });

  /// Mirrors RayBanMetaDeviceConnection.autoCaptureInterval: the glasses' capture cadence.
  final Duration interval;

  /// photo ticks or recorded segments; fixed for the service's lifetime.
  final ChestCameraMode mode;

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
  /// A [ChestCameraMode.video] tick records one clip, then hands its keyframe
  /// (as a `segment` ChestCapture) and the clip bytes to the handlers.
  Future<void> _captureTick(ChestPhotoHandler onPhoto) async {
    if (_capturing || _stopping) return;
    _capturing = true;
    try {
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) {
        await _reopen();
        return;
      }
      switch (mode) {
        case ChestCameraMode.photo:
          final file = await controller.takePicture();
          try {
            final bytes = await file.readAsBytes();
            if (!_stopping && bytes.isNotEmpty) {
              onPhoto(ChestCapture(kind: 'photo', jpegBytes: bytes, capturedAt: DateTime.now()));
            }
          } finally {
            // takePicture writes into the app cache; one file per tick must not
            // accumulate over a multi-hour session.
            unawaited(_deleteQuietly(file.path));
          }
        case ChestCameraMode.video:
          final clip = await _recordSegment(controller);
          if (clip == null) return;
          try {
            // The clip's first frame is the segment's keyframe: same describe
            // pipeline as a photo, `segment` kind so the ingest can label it.
            final keyframe = _extractKeyframe(clip);
            if (keyframe != null && !_stopping && keyframe.isNotEmpty) {
              onPhoto(ChestCapture(kind: 'segment', jpegBytes: keyframe, capturedAt: DateTime.now()));
            }
          } finally {
            unawaited(_deleteQuietly(clip.path));
          }
      }
    } catch (e) {
      // A missed frame never ends the session; the next tick reopens if closed.
      Logger.debug('ChestCamera: capture failed: ${e.runtimeType}');
      unawaited(_reopenIfClosed());
    } finally {
      _capturing = false;
    }
  }

  /// Records exactly [interval] of video and returns the finished file.
  /// Null when the record could not start (camera contention, storage).
  Future<XFile?> _recordSegment(CameraController controller) async {
    // Stop any recording from a previous tick before starting a new one; the
    // periodic tick owns the camera exclusively.
    if (controller.value.isRecordingVideo) {
      try {
        await controller.stopVideoRecording();
      } catch (_) {}
    }
    try {
      await controller.startVideoRecording();
      await Future<void>.delayed(interval);
      if (!controller.value.isRecordingVideo) return null;
      return await controller.stopVideoRecording();
    } catch (e) {
      Logger.debug('ChestCamera: segment record failed: ${e.runtimeType}');
      try {
        if (controller.value.isRecordingVideo) await controller.stopVideoRecording();
      } catch (_) {}
      return null;
    }
  }

  /// First frame of a recorded clip as JPEG bytes, or null when extraction
  /// fails. The camera plugin records MP4 with no JPEG option, so the keyframe
  /// comes from decoding the container's first frame — the `image` package
  /// ships no video demuxer, so this uses the platform's thumbnail seam
  /// (native channel); when that is unavailable the tick degrades to no photo
  /// rather than a wrong frame.
  Uint8List? _extractKeyframe(XFile clip) => _keyframeExtractor?.call(clip);

  /// Set by the embedding native bridge once; null when the host has no
  /// thumbnail extractor (then video mode yields no keyframe photos).
  static Uint8List? Function(XFile clip)? _keyframeExtractor;

  /// Test/bridge seam registration for the keyframe extractor.
  static set keyframeExtractor(Uint8List? Function(XFile clip)? extractor) => _keyframeExtractor = extractor;

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
      // A recording in flight is stopped before disposal so the plugin's camera
      // session unwinds cleanly (an aborted record left pending can wedge the
      // native capture session on some devices).
      if (controller?.value.isRecordingVideo ?? false) {
        try {
          await controller?.stopVideoRecording();
        } catch (_) {}
      }
      await controller?.dispose();
    } catch (_) {}
    await keepScreenOn(false);
    _stopping = false;
  }
}
