import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/capture/chest_camera_service.dart';

/// The camera plugin needs real platform channels, so a hermetic test can
/// cover the start gates (permission, camera list, controller open) and the
/// stop cleanup, but not an actual capture tick — that stays on-device.
/// Under `flutter test` even a successful permission + camera list falls at
/// `CameraController.initialize` (MissingPluginException), which the service
/// must swallow into `start() == false`.
void main() {
  test('start refuses without the camera permission', () async {
    final keepScreenOnCalls = <bool>[];
    final service = ChestCameraService(
      ensurePermission: () async => false,
      listCameras: () async => [],
      keepScreenOn: (on) async => keepScreenOnCalls.add(on),
    );
    expect(await service.start(onPhoto: (_) {}), isFalse);
    expect(service.isRunning, isFalse);
    expect(keepScreenOnCalls, isEmpty);
  });

  test('start refuses when no camera exists', () async {
    final service = ChestCameraService(
      ensurePermission: () async => true,
      listCameras: () async => [],
      keepScreenOn: (_) async => throw StateError('unreached: no camera to hold the screen for'),
    );
    expect(await service.start(onPhoto: (_) {}), isFalse);
    expect(service.isRunning, isFalse);
  });

  test('a camera whose plugin channels are absent starts false and stays stopped', () async {
    final keepScreenOnCalls = <bool>[];
    final service = ChestCameraService(
      ensurePermission: () async => true,
      // A real description; `CameraController.initialize` then fails under test.
      listCameras: () async => const [
        CameraDescription(name: 'back', lensDirection: CameraLensDirection.back, sensorOrientation: 90),
      ],
      keepScreenOn: (on) async => keepScreenOnCalls.add(on),
    );
    expect(await service.start(onPhoto: (_) {}), isFalse);
    expect(service.isRunning, isFalse);
    expect(keepScreenOnCalls, isEmpty);
    await service.stop(); // idempotent on a never-started service
    expect(service.isRunning, isFalse);
  });
}
