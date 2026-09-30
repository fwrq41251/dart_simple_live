import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

/// 回放播放控制器。
///
/// 与直播（LiveRoomController）语义不同：回放是可 seek 的点播，
/// 需要进度、暂停、倍速，不需要追流与断线重连，因此独立实现。
class ReplayController extends BaseController with WindowListener {
  final Site pSite;
  final String pRoomId;
  final LiveReplayItem pItem;

  ReplayController({
    required this.pSite,
    required this.pRoomId,
    required this.pItem,
  });

  late Rx<Site> rxSite = pSite.obs;
  Site get site => rxSite.value;

  late final player = Player(
    configuration: const PlayerConfiguration(
      title: "Simple Live Player",
      logLevel: MPVLogLevel.error,
    ),
  );

  late final videoController = VideoController(
    player,
    configuration: VideoControllerConfiguration(
      enableHardwareAcceleration:
          AppSettingsController.instance.hardwareDecode.value,
    ),
  );

  GlobalKey<VideoState> globalPlayerKey = GlobalKey<VideoState>();

  /// 可用清晰度
  var qualities = <LiveReplayQuality>[].obs;

  /// 当前清晰度索引
  var currentQuality = (-1).obs;

  /// 加载中
  var loading = true.obs;

  /// 加载失败
  var loadError = false.obs;

  /// 播放位置
  var position = Duration.zero.obs;

  /// 总时长
  var duration = Duration.zero.obs;

  /// 是否播放中
  var playing = false.obs;

  /// 倍速
  var speed = 1.0.obs;

  /// 全屏
  var fullScreen = false.obs;

  /// 路由只有在播放器停止后才允许退出。
  var allowPop = false.obs;

  /// 显示控制条
  var showControls = true.obs;

  Timer? _hideControlsTimer;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  StreamSubscription? _playingSubscription;
  StreamSubscription? _errorSubscription;
  StreamSubscription? _completedSubscription;
  Future<void> _playerOperations = Future<void>.value();
  Future<void>? _prepareForExitFuture;
  bool _closing = false;
  bool _exitRequested = false;
  bool _playerDisposed = false;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool get closing => _closing;

  @override
  void onInit() {
    super.onInit();
    if (_isDesktop) {
      windowManager.addListener(this);
    }
    initStream();
    loadData();
  }

  void initStream() {
    _positionSubscription = player.stream.position.listen((e) {
      position.value = e;
    });
    _durationSubscription = player.stream.duration.listen((e) {
      duration.value = e;
    });
    _playingSubscription = player.stream.playing.listen((e) {
      if (_closing) {
        return;
      }
      playing.value = e;
      if (e) {
        WakelockPlus.enable();
      } else {
        WakelockPlus.disable();
      }
    });
    _errorSubscription = player.stream.error.listen((e) {
      if (_closing) {
        return;
      }
      Log.d("回放播放器错误：$e");
      if (e.contains('no sound.')) {
        return;
      }
      SmartDialog.showToast("播放失败:$e");
    });
    _completedSubscription = player.stream.completed.listen((e) {
      if (e) {
        WakelockPlus.disable();
      }
    });
  }

  /// 读取回放地址
  Future<void> loadData() async {
    if (_closing) {
      return;
    }
    loading.value = true;
    loadError.value = false;
    try {
      var result = await site.liveSite.getReplayUrl(
        roomId: pRoomId,
        hashId: pItem.hashId,
      );
      if (_closing) {
        return;
      }
      if (result.qualities.isEmpty) {
        loadError.value = true;
        SmartDialog.showToast("无法读取回放地址");
        return;
      }
      qualities.value = result.qualities;
      // 默认选最高清晰度
      currentQuality.value = 0;
      await playCurrent();
    } catch (e) {
      if (_closing) {
        return;
      }
      Log.logPrint(e);
      loadError.value = true;
      SmartDialog.showToast("无法读取回放地址");
    } finally {
      if (!_closing) {
        loading.value = false;
      }
    }
  }

  Future<void> _runPlayerOperation(
    Future<void> Function() operation,
  ) {
    if (_closing) {
      return Future<void>.value();
    }
    final result = _playerOperations.then((_) async {
      if (!_closing) {
        await operation();
      }
    });
    _playerOperations = result.catchError((_) {});
    return result;
  }

  Future<void> playCurrent() async {
    if (_closing ||
        currentQuality.value < 0 ||
        currentQuality.value >= qualities.length) {
      return;
    }
    var url = qualities[currentQuality.value].url;
    await _runPlayerOperation(() => player.open(Media(url)));
  }

  /// 切换清晰度（保留播放位置）
  Future<void> changeQuality(int index) async {
    if (_closing || index == currentQuality.value) {
      return;
    }
    var last = position.value;
    currentQuality.value = index;
    await playCurrent();
    if (!_closing && last > Duration.zero) {
      await seekTo(last);
    }
  }

  /// 拖动进度，并将越界值限制在有效范围内。
  Future<void> seekTo(Duration value) async {
    if (_closing) {
      return;
    }
    var milliseconds = value.inMilliseconds;
    if (milliseconds < 0) {
      milliseconds = 0;
    }
    var total = duration.value.inMilliseconds;
    if (total > 0 && milliseconds > total) {
      milliseconds = total;
    }
    var target = Duration(milliseconds: milliseconds);
    await _runPlayerOperation(() => player.seek(target));
    if (!_closing) {
      position.value = target;
    }
  }

  Future<void> togglePlay() async {
    if (playing.value) {
      await _runPlayerOperation(player.pause);
    } else {
      await _runPlayerOperation(player.play);
    }
  }

  Future<void> setSpeed(double value) async {
    speed.value = value;
    await _runPlayerOperation(() => player.setRate(value));
  }

  void showControlsTemporarily() {
    if (_closing) {
      return;
    }
    showControls.value = true;
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (!_closing) {
        showControls.value = false;
      }
    });
  }

  Future<void> toggleFullScreen() async {
    if (_closing) {
      return;
    }
    var enter = !fullScreen.value;
    if (_isDesktop) {
      await windowManager.setFullScreen(enter);
      fullScreen.value = enter;
      return;
    }

    fullScreen.value = enter;
    if (enter) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  void onWindowEnterFullScreen() {
    fullScreen.value = true;
  }

  @override
  void onWindowLeaveFullScreen() {
    fullScreen.value = false;
  }

  /// 停止播放器后才允许路由退出，避免 Windows 原生纹理释放竞争。
  Future<void> prepareForExit() {
    return _prepareForExitFuture ??= _prepareForExit();
  }

  Future<bool> requestExit() async {
    if (_exitRequested) {
      return false;
    }
    _exitRequested = true;
    await prepareForExit();
    allowPop.value = true;
    return true;
  }

  Future<void> _prepareForExit() async {
    _closing = true;
    _hideControlsTimer?.cancel();
    try {
      await _playerOperations;
    } catch (e) {
      Log.logPrint(e);
    }
    try {
      await player.stop();
    } catch (e) {
      Log.logPrint(e);
    }
    await WakelockPlus.disable();
  }

  Future<void> _disposePlayer() async {
    await prepareForExit();
    try {
      if (_isDesktop) {
        if (await windowManager.isFullScreen()) {
          await windowManager.setFullScreen(false);
        }
      } else {
        await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    } catch (e) {
      Log.logPrint(e);
    }
    if (!_playerDisposed) {
      _playerDisposed = true;
      try {
        await player.dispose();
      } catch (e) {
        Log.logPrint(e);
      }
    }
  }

  @override
  void onClose() async {
    if (_isDesktop) {
      windowManager.removeListener(this);
    }
    _hideControlsTimer?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playingSubscription?.cancel();
    _errorSubscription?.cancel();
    _completedSubscription?.cancel();
    await _disposePlayer();
    super.onClose();
  }
}
