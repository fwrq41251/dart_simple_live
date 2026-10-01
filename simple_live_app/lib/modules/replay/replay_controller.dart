import 'dart:async';
import 'dart:io';
import 'package:canvas_danmaku/canvas_danmaku.dart';
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
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

/// 回放播放控制器。
///
/// 与直播（LiveRoomController）语义不同：回放是可 seek 的点播，
/// 需要进度、暂停、倍速，不需要追流与断线重连，因此独立实现。
class ReplayController extends BaseController with WindowListener {
  static const _minimumSavedProgress = Duration(seconds: 10);
  static const _completedProgressThreshold = Duration(seconds: 30);
  static const _progressSaveInterval = Duration(seconds: 10);

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
  GlobalKey globalDanmakuKey = GlobalKey();

  DanmakuController? danmakuController;
  Widget? danmakuView;
  bool _danmakuControllerReady = false;

  bool get supportsReplayDanmaku => site.liveSite is LiveReplayDanmakuSite;

  /// 是否显示回放弹幕。
  var showDanmaku = false.obs;

  final List<LiveReplayDanmaku> _danmakus = [];
  int _danmakuRangeStart = 0;
  int _danmakuRangeEnd = -2;
  int _nextDanmakuIndex = 0;
  int? _lastDanmakuPosition;
  int? _loadingDanmakuAt;
  int _danmakuRequestGeneration = 0;
  DateTime? _danmakuRetryAfter;

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
  Future<void> _progressOperations = Future<void>.value();
  Future<void>? _prepareForExitFuture;
  DateTime? _lastProgressSavedAt;
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
    showDanmaku.value = supportsReplayDanmaku &&
        AppSettingsController.instance.danmuEnable.value;
    initStream();
    loadData();
  }

  void initStream() {
    _positionSubscription = player.stream.position.listen((e) {
      onReplayPositionChanged(e);
    });
    _durationSubscription = player.stream.duration.listen((e) {
      duration.value = e;
    });
    _playingSubscription = player.stream.playing.listen((e) {
      if (_closing) {
        return;
      }
      playing.value = e;
      onReplayPlayingChanged(e);
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
        onReplayCompleted();
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
      var restoredPosition = await restoreReplayProgress();
      if (_closing) {
        return;
      }
      position.value = restoredPosition;
      await playCurrent(
        start: restoredPosition > Duration.zero ? restoredPosition : null,
      );
      if (showDanmaku.value) {
        unawaited(loadReplayDanmakuAt(position.value.inMilliseconds));
      }
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

  Future<void> playCurrent({Duration? start, bool play = true}) async {
    if (_closing ||
        currentQuality.value < 0 ||
        currentQuality.value >= qualities.length) {
      return;
    }
    var url = qualities[currentQuality.value].url;
    await _runPlayerOperation(
      () => player.open(Media(url, start: start), play: play),
    );
  }

  /// 切换清晰度（保留播放位置）
  Future<void> changeQuality(int index) async {
    if (_closing || index == currentQuality.value) {
      return;
    }
    var last = position.value;
    var wasPlaying = playing.value;
    currentQuality.value = index;
    await playCurrent(
      start: last > Duration.zero ? last : null,
      play: wasPlaying,
    );
    if (!_closing) {
      position.value = last;
      await synchronizeDanmakuAfterSeek(last);
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
      await synchronizeDanmakuAfterSeek(target);
      await saveReplayProgress(force: true, clearAtStart: true);
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
    updateDanmakuOption();
  }

  void initDanmakuController(DanmakuController controller) {
    danmakuController = controller;
    _danmakuControllerReady = false;
    // canvas_danmaku 会在 State 的动画控制器初始化前回调 createdController。
    // 等首帧完成后再操作，避免初始 position 事件触发 clear/pause 时崩溃。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_closing || !identical(danmakuController, controller)) {
        return;
      }
      _danmakuControllerReady = true;
      updateDanmakuOption();
      if (playing.value) {
        controller.resume();
      } else {
        controller.pause();
      }
    });
  }

  DanmakuOption get danmakuOption {
    var settings = AppSettingsController.instance;
    return DanmakuOption(
      fontSize: settings.danmuSize.value,
      area: settings.danmuArea.value,
      duration: (settings.danmuSpeed.value / speed.value)
          .round()
          .clamp(1, 60)
          .toInt(),
      opacity: settings.danmuOpacity.value,
      fontWeight: settings.danmuFontWeight.value,
    );
  }

  void updateDanmakuOption() {
    if (_danmakuControllerReady) {
      danmakuController?.updateOption(danmakuOption);
    }
  }

  void toggleDanmaku() {
    if (!supportsReplayDanmaku) {
      return;
    }
    showDanmaku.value = !showDanmaku.value;
    if (!showDanmaku.value) {
      if (_danmakuControllerReady) {
        danmakuController?.clear();
      }
      return;
    }
    unawaited(synchronizeDanmakuAfterSeek(position.value));
  }

  @visibleForTesting
  void onReplayPlayingChanged(bool value) {
    if (!value) {
      unawaited(saveReplayProgress(force: true));
    }
    if (!showDanmaku.value || !_danmakuControllerReady) {
      return;
    }
    if (value) {
      danmakuController?.resume();
    } else {
      danmakuController?.pause();
    }
  }

  bool _danmakuRangeContains(int milliseconds) =>
      _danmakuRangeEnd != -2 &&
      milliseconds >= _danmakuRangeStart &&
      (_danmakuRangeEnd == -1 || milliseconds <= _danmakuRangeEnd);

  int _lowerBoundDanmaku(int milliseconds) {
    var low = 0;
    var high = _danmakus.length;
    while (low < high) {
      var middle = (low + high) >> 1;
      if (_danmakus[middle].time < milliseconds) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  @visibleForTesting
  Future<void> loadReplayDanmakuAt(
    int milliseconds, {
    bool force = false,
  }) async {
    if (_closing || !showDanmaku.value || !supportsReplayDanmaku) {
      return;
    }
    if (_danmakuRangeContains(milliseconds)) {
      _nextDanmakuIndex = _lowerBoundDanmaku(milliseconds);
      return;
    }
    if (!force && _loadingDanmakuAt != null) {
      return;
    }
    var retryAfter = _danmakuRetryAfter;
    if (!force && retryAfter != null && DateTime.now().isBefore(retryAfter)) {
      return;
    }

    var generation = ++_danmakuRequestGeneration;
    _loadingDanmakuAt = milliseconds;
    try {
      var replayDanmakuSite = site.liveSite as LiveReplayDanmakuSite;
      var result = await replayDanmakuSite.getReplayDanmaku(
        hashId: pItem.hashId,
        startTime: milliseconds,
      );
      if (_closing || generation != _danmakuRequestGeneration) {
        return;
      }
      _danmakus
        ..clear()
        ..addAll(result.items);
      _danmakuRangeStart = result.startTime;
      _danmakuRangeEnd = result.endTime;
      _nextDanmakuIndex = _lowerBoundDanmaku(position.value.inMilliseconds);
      _danmakuRetryAfter = null;
    } catch (e) {
      Log.logPrint(e);
      if (generation == _danmakuRequestGeneration) {
        // 弹幕是附加能力，失败不能影响回放；短暂退避避免每个 position
        // 事件都重新请求同一个失败接口。
        _danmakuRetryAfter = DateTime.now().add(const Duration(seconds: 10));
      }
    } finally {
      if (generation == _danmakuRequestGeneration) {
        _loadingDanmakuAt = null;
      }
    }
  }

  @visibleForTesting
  void onReplayPositionChanged(Duration value) {
    position.value = value;
    unawaited(saveReplayProgress());
    if (_closing || !showDanmaku.value || !supportsReplayDanmaku) {
      return;
    }

    var milliseconds = value.inMilliseconds;
    var last = _lastDanmakuPosition;
    if (last != null &&
        (milliseconds < last || (milliseconds - last).abs() > 2000)) {
      unawaited(synchronizeDanmakuAfterSeek(value));
      return;
    }
    _lastDanmakuPosition = milliseconds;

    if (!_danmakuRangeContains(milliseconds)) {
      unawaited(loadReplayDanmakuAt(milliseconds));
      return;
    }

    while (_nextDanmakuIndex < _danmakus.length &&
        _danmakus[_nextDanmakuIndex].time <= milliseconds) {
      var item = _danmakus[_nextDanmakuIndex++];
      // 异步加载刚完成或系统调度延迟时不补发大量过期弹幕。
      if (item.time > (last ?? milliseconds - 500)) {
        emitReplayDanmaku(item);
      }
    }
  }

  String get replayProgressId => "${site.id}_${pRoomId}_${pItem.hashId}";

  Duration get _knownDuration => duration.value > Duration.zero
      ? duration.value
      : Duration(seconds: pItem.duration);

  @visibleForTesting
  int? readReplayProgress() {
    return DBService.instance.getReplayProgress(replayProgressId);
  }

  @visibleForTesting
  Future<void> writeReplayProgress(int milliseconds) {
    return DBService.instance.saveReplayProgress(
      replayProgressId,
      milliseconds,
    );
  }

  @visibleForTesting
  Future<void> removeReplayProgress() {
    return DBService.instance.removeReplayProgress(replayProgressId);
  }

  Future<Duration> restoreReplayProgress() async {
    var milliseconds = readReplayProgress();
    if (milliseconds == null ||
        milliseconds < _minimumSavedProgress.inMilliseconds) {
      return Duration.zero;
    }
    var savedPosition = Duration(milliseconds: milliseconds);
    var total = _knownDuration;
    if (total > Duration.zero &&
        savedPosition >= total - _completedProgressThreshold) {
      await removeReplayProgress();
      return Duration.zero;
    }
    return savedPosition;
  }

  Future<void> saveReplayProgress({
    bool force = false,
    bool clearAtStart = false,
  }) {
    if (_closing) {
      return Future<void>.value();
    }
    var now = DateTime.now();
    var lastSavedAt = _lastProgressSavedAt;
    if (!force &&
        lastSavedAt != null &&
        now.difference(lastSavedAt) < _progressSaveInterval) {
      return Future<void>.value();
    }

    var current = position.value;
    var total = _knownDuration;
    late Future<void> Function() operation;
    if ((clearAtStart && current < _minimumSavedProgress) ||
        (total > Duration.zero &&
            current >= total - _completedProgressThreshold)) {
      operation = removeReplayProgress;
    } else if (current < _minimumSavedProgress) {
      return Future<void>.value();
    } else {
      operation = () => writeReplayProgress(current.inMilliseconds);
    }
    _lastProgressSavedAt = now;
    var result = _progressOperations.then((_) => operation());
    _progressOperations = result.catchError((e) => Log.logPrint(e));
    return _progressOperations;
  }

  @visibleForTesting
  void onReplayCompleted() {
    unawaited(_queueRemoveReplayProgress());
  }

  Future<void> _queueRemoveReplayProgress() {
    var result = _progressOperations.then((_) => removeReplayProgress());
    _progressOperations = result.catchError((e) => Log.logPrint(e));
    return _progressOperations;
  }

  @visibleForTesting
  Future<void> synchronizeDanmakuAfterSeek(Duration value) async {
    if (!showDanmaku.value || !supportsReplayDanmaku) {
      return;
    }
    var milliseconds = value.inMilliseconds;
    if (_danmakuControllerReady) {
      danmakuController?.clear();
      if (playing.value) {
        danmakuController?.resume();
      }
    }
    _lastDanmakuPosition = milliseconds;
    if (_danmakuRangeContains(milliseconds)) {
      _nextDanmakuIndex = _lowerBoundDanmaku(milliseconds);
      return;
    }
    await loadReplayDanmakuAt(milliseconds, force: true);
  }

  @visibleForTesting
  void emitReplayDanmaku(LiveReplayDanmaku item) {
    if (_danmakuControllerReady) {
      danmakuController?.addDanmaku(
        DanmakuContentItem(item.text, color: Color(item.color)),
      );
    }
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
    await saveReplayProgress(force: true);
    await _progressOperations;
    _closing = true;
    _danmakuRequestGeneration++;
    if (_danmakuControllerReady) {
      danmakuController?.clear();
    }
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
