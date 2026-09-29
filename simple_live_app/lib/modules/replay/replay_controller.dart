import 'dart:async';

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

/// 回放播放控制器。
///
/// 与直播（LiveRoomController）语义不同：回放是可 seek 的点播，
/// 需要进度、暂停、倍速，不需要追流与断线重连，因此独立实现。
class ReplayController extends BaseController {
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

  /// 显示控制条
  var showControls = true.obs;

  Timer? _hideControlsTimer;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  StreamSubscription? _playingSubscription;
  StreamSubscription? _errorSubscription;
  StreamSubscription? _completedSubscription;

  @override
  void onInit() {
    super.onInit();
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
      playing.value = e;
      if (e) {
        WakelockPlus.enable();
      } else {
        WakelockPlus.disable();
      }
    });
    _errorSubscription = player.stream.error.listen((e) {
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
    loading.value = true;
    loadError.value = false;
    try {
      var result = await site.liveSite.getReplayUrl(
        roomId: pRoomId,
        hashId: pItem.hashId,
      );
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
      Log.logPrint(e);
      loadError.value = true;
      SmartDialog.showToast("无法读取回放地址");
    } finally {
      loading.value = false;
    }
  }

  Future<void> playCurrent() async {
    if (currentQuality.value < 0 ||
        currentQuality.value >= qualities.length) {
      return;
    }
    var url = qualities[currentQuality.value].url;
    await player.open(Media(url));
  }

  /// 切换清晰度（保留播放位置）
  Future<void> changeQuality(int index) async {
    if (index == currentQuality.value) {
      return;
    }
    var last = position.value;
    currentQuality.value = index;
    await playCurrent();
    if (last > Duration.zero) {
      await player.seek(last);
    }
  }

  /// 拖动进度
  Future<void> seekTo(Duration value) async {
    await player.seek(value);
    position.value = value;
  }

  Future<void> togglePlay() async {
    if (playing.value) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  Future<void> setSpeed(double value) async {
    speed.value = value;
    await player.setRate(value);
  }

  void showControlsTemporarily() {
    showControls.value = true;
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      showControls.value = false;
    });
  }

  void toggleFullScreen() {
    fullScreen.value = !fullScreen.value;
    if (fullScreen.value) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  void onClose() {
    _hideControlsTimer?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playingSubscription?.cancel();
    _errorSubscription?.cancel();
    _completedSubscription?.cancel();
    player.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.onClose();
  }
}
