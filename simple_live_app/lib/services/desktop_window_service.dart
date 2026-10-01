import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:get/get.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:window_manager/window_manager.dart';

class DesktopWindowService extends GetxService with WindowListener {
  static DesktopWindowService get instance => Get.find<DesktopWindowService>();

  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Rect? _normalBounds;
  Offset? _smallWindowPosition;
  bool _smallWindow = false;
  bool _restoring = false;
  Timer? _saveTimer;

  Offset? get smallWindowPosition => _smallWindowPosition;

  Future<void> init() async {
    if (!isDesktop) {
      return;
    }
    _normalBounds = decodeRect(
      LocalStorageService.instance.getValue<List>(
        LocalStorageService.kDesktopWindowBounds,
        const [],
      ),
    );
    _smallWindowPosition = decodeOffset(
      LocalStorageService.instance.getValue<List>(
        LocalStorageService.kDesktopSmallWindowPosition,
        const [],
      ),
    );
    windowManager.addListener(this);

    const options = WindowOptions(
      minimumSize: Size(280, 280),
      center: true,
      title: "Simple Live",
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      var bounds = _normalBounds;
      if (bounds != null) {
        _restoring = true;
        await windowManager.setBounds(bounds);
        _restoring = false;
      }
      await windowManager.show();
      await windowManager.focus();
    });
  }

  Future<void> beginSmallWindow() async {
    _saveTimer?.cancel();
    _normalBounds = await windowManager.getBounds();
    await _saveNormalBounds();
    _smallWindow = true;
  }

  Future<void> restoreNormalWindow() async {
    _saveTimer?.cancel();
    _smallWindowPosition = await windowManager.getPosition();
    await LocalStorageService.instance.setValue(
      LocalStorageService.kDesktopSmallWindowPosition,
      encodeOffset(_smallWindowPosition!),
    );
    _smallWindow = false;
    var bounds = _normalBounds;
    if (bounds != null) {
      _restoring = true;
      await windowManager.setBounds(bounds);
      _restoring = false;
    }
  }

  @override
  void onWindowMove() => _scheduleSave();

  @override
  void onWindowResize() => _scheduleSave();

  void _scheduleSave() {
    if (_restoring) {
      return;
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _saveWindowState);
  }

  Future<void> _saveWindowState() async {
    if (_smallWindow) {
      _smallWindowPosition = await windowManager.getPosition();
      await LocalStorageService.instance.setValue(
        LocalStorageService.kDesktopSmallWindowPosition,
        encodeOffset(_smallWindowPosition!),
      );
      return;
    }
    if (await windowManager.isFullScreen() ||
        await windowManager.isMaximized()) {
      return;
    }
    _normalBounds = await windowManager.getBounds();
    await _saveNormalBounds();
  }

  Future<void> _saveNormalBounds() async {
    var bounds = _normalBounds;
    if (bounds == null) {
      return;
    }
    await LocalStorageService.instance.setValue(
      LocalStorageService.kDesktopWindowBounds,
      encodeRect(bounds),
    );
  }

  static List<double> encodeRect(Rect value) => [
        value.left,
        value.top,
        value.width,
        value.height,
      ];

  static Rect? decodeRect(List value) {
    if (value.length != 4 || value.any((item) => item is! num)) {
      return null;
    }
    var numbers = value.cast<num>().map((item) => item.toDouble()).toList();
    if (numbers.any((item) => !item.isFinite) ||
        numbers[2] < 280 ||
        numbers[3] < 280) {
      return null;
    }
    return Rect.fromLTWH(numbers[0], numbers[1], numbers[2], numbers[3]);
  }

  static List<double> encodeOffset(Offset value) => [value.dx, value.dy];

  static Offset? decodeOffset(List value) {
    if (value.length != 2 || value.any((item) => item is! num)) {
      return null;
    }
    var x = (value[0] as num).toDouble();
    var y = (value[1] as num).toDouble();
    if (!x.isFinite || !y.isFinite) {
      return null;
    }
    return Offset(x, y);
  }

  @override
  void onClose() {
    _saveTimer?.cancel();
    if (isDesktop) {
      windowManager.removeListener(this);
    }
    super.onClose();
  }
}
