import 'dart:async';

import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/models/db/history.dart';
import 'package:simple_live_tv_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:simple_live_tv_app/services/diagnostic_service.dart';
import 'package:simple_live_tv_app/services/follow_user_service.dart';

class LiveRoomController extends PlayerController with WidgetsBindingObserver {
  final Site pSite;
  final String pRoomId;
  late LiveDanmaku liveDanmaku;
  LiveRoomController({required this.pSite, required this.pRoomId}) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    liveDanmaku = site.liveSite.getDanmaku();
  }
  final FocusNode focusNode = FocusNode();
  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  var liveStatus = false.obs;

  /// 清晰度数据
  RxList<LivePlayQuality> qualites = RxList<LivePlayQuality>();

  /// 当前清晰度
  var currentQuality = -1;
  var currentQualityInfo = "".obs;

  /// 线路数据
  RxList<String> playUrls = RxList<String>();

  Map<String, String>? playHeaders;

  /// 当前线路
  var currentLineIndex = -1;
  var currentLineInfo = "".obs;

  /// 是否处于后台
  var isBackground = false;

  /// 播放恢复状态；空字符串表示无需向用户提示。
  final recoveryStatus = "".obs;
  bool get canManuallyRetry => _automaticRecoveryExhausted;

  var datetime = "00:00".obs;

  void initTimer() {
    Timer.periodic(const Duration(seconds: 1), (timer) {
      var now = DateTime.now();
      datetime.value =
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
    });
  }

  /// 双击退出Flag
  bool doubleClickExit = false;

  /// 双击退出Timer
  Timer? doubleClickTimer;

  @override
  void onInit() {
    initTimer();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");

    loadData();

    super.onInit();
  }

  void refreshRoom() {
    _resetRecoveryState();
    //messages.clear();

    liveDanmaku.stop();

    loadData();
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    liveDanmaku.onMessage = onWSMessage;
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (msg.type == LiveMessageType.chat) {
      // 关键词屏蔽检查
      for (var keyword in AppSettingsController.instance.shieldList) {
        Pattern? pattern;
        if (Utils.isRegexFormat(keyword)) {
          String removedSlash = Utils.removeRegexFormat(keyword);
          try {
            pattern = RegExp(removedSlash);
          } catch (e) {
            // should avoid this during add keyword
            Log.d("关键词：$keyword 正则格式错误");
          }
        } else {
          pattern = keyword;
        }
        if (pattern != null && msg.message.contains(pattern)) {
          Log.d("关键词：$keyword\n已屏蔽消息内容：${msg.message}");
          return;
        }
      }

      if (!liveStatus.value || isBackground) {
        return;
      }

      addDanmaku([
        DanmakuContentItem(
          msg.message,
          color: Color.fromARGB(255, msg.color.r, msg.color.g, msg.color.b),
        ),
      ]);
    } else if (msg.type == LiveMessageType.online) {
      online.value = msg.data;
    } else if (msg.type == LiveMessageType.superChat) {
      //superChats.add(msg.data);
    }
  }

  /// 加载直播间信息
  void loadData() async {
    try {
      SmartDialog.showLoading(msg: "");
      pageLoadding.value = true;
      detail.value = await site.liveSite.getRoomDetail(roomId: roomId);
      DiagnosticService.instance.updateRoom(
        platform: site.name,
        roomId: roomId,
      );

      addHistory();
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      if (liveStatus.value) {
        getPlayQualites();
      }
      if (detail.value!.isRecord) {
        SmartDialog.showToast("当前主播未开播，正在轮播录像");
      }

      initDanmau();
      liveDanmaku.start(detail.value?.danmakuData);
    } catch (e) {
      SmartDialog.showToast(e.toString());
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
      pageLoadding.value = false;
    }
  }

  /// 初始化播放器
  void getPlayQualites() async {
    qualites.clear();
    currentQuality = -1;
    try {
      var playQualites = await site.liveSite.getPlayQualites(
        detail: detail.value!,
      );

      if (playQualites.isEmpty) {
        SmartDialog.showToast("无法读取播放清晰度");
        return;
      }
      qualites.value = playQualites;
      var qualityLevel = AppSettingsController.instance.qualityLevel.value;
      if (qualityLevel == 2) {
        //最高
        currentQuality = 0;
      } else if (qualityLevel == 0) {
        //最低
        currentQuality = playQualites.length - 1;
      } else {
        //中间值
        int middle = (playQualites.length / 2).floor();
        currentQuality = middle;
      }

      getPlayUrl();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法读取播放清晰度");
    }
  }

  Future<bool> getPlayUrl({
    bool notifyError = true,
    bool resetRecovery = true,
    int? recoveryGeneration,
  }) async {
    if (resetRecovery) {
      _resetRecoveryState();
    }
    if (qualites.isEmpty ||
        currentQuality < 0 ||
        currentQuality >= qualites.length) {
      if (notifyError) {
        SmartDialog.showToast("无法读取播放清晰度");
      }
      return false;
    }
    playUrls.clear();
    currentQualityInfo.value = qualites[currentQuality].quality;
    currentLineInfo.value = "";
    currentLineIndex = -1;
    var stopwatch = Stopwatch()..start();
    LivePlayUrl playUrl;
    try {
      playUrl = await site.liveSite.getPlayUrls(
        detail: detail.value!,
        quality: qualites[currentQuality],
      );
      DiagnosticService.instance.recordUrlRequest(
        stopwatch.elapsed,
        playUrl.urls.isEmpty ? '无可用地址' : '成功',
      );
    } on DioException catch (e) {
      DiagnosticService.instance.recordUrlRequest(
        stopwatch.elapsed,
        'HTTP ${e.response?.statusCode ?? '未知'}',
      );
      rethrow;
    } catch (_) {
      DiagnosticService.instance.recordUrlRequest(stopwatch.elapsed, '失败');
      rethrow;
    }
    if (recoveryGeneration != null &&
        recoveryGeneration != _recoveryGeneration) {
      return false;
    }
    if (playUrl.urls.isEmpty) {
      if (notifyError) {
        SmartDialog.showToast("无法读取播放地址");
      }
      return false;
    }
    playUrls.value = playUrl.urls;
    playHeaders = playUrl.headers;
    currentLineIndex = 0;
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    _updateDiagnosticContext();
    await setPlayer();
    return true;
  }

  Future<void> changePlayLine(int index) async {
    _resetRecoveryState();
    currentLineIndex = index;
    _updateDiagnosticContext();
    await setPlayer();
  }

  void _updateDiagnosticContext() {
    DiagnosticService.instance.updateRoom(
      platform: site.name,
      roomId: roomId,
      quality: currentQualityInfo.value,
      line: "线路${currentLineIndex + 1}",
    );
  }

  Future<void> setPlayer() async {
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";
    // 初始化播放器并设置 ao 参数
    await initializePlayer();
    await player.open(
      Media(playUrls[currentLineIndex], httpHeaders: playHeaders),
    );

    Log.d("播放链接\r\n：${playUrls[currentLineIndex]}");
  }

  @override
  void mediaEnd() {
    super.mediaEnd();
    DiagnosticService.instance.recordRecovery('播放器报告流结束');
    unawaited(_recoverPlayback("播放结束", reloadCurrentUrl: site.id != "douyu"));
  }

  int mediaErrorRetryCount = 0;
  @override
  void mediaError(String error) {
    super.mediaError(error);
    DiagnosticService.instance.recordPlayerError(error);
    unawaited(_recoverPlayback("播放失败:$error"));
  }

  bool _recoveringPlayback = false;
  bool _awaitingStablePlayback = false;
  bool _automaticRecoveryExhausted = false;
  bool _reportedPlaying = false;
  Timer? _stablePlaybackTimer;
  int _freshUrlAttempts = 0;
  static const int _maxFreshUrlAttempts = 3;
  DateTime? _lastRecoveryEventAt;
  int _recoveryGeneration = 0;

  @protected
  Duration get stablePlaybackDuration => const Duration(seconds: 10);
  @protected
  Duration get recoveryBaseDelay => const Duration(milliseconds: 500);
  @protected
  Duration get recoveryMaxDelay => const Duration(seconds: 30);
  @protected
  Duration get recoveryBurstWindow => const Duration(milliseconds: 800);

  Duration recoveryDelayFor(int attempt) {
    var exponent = attempt <= 1 ? 0 : attempt - 1;
    var millis = recoveryBaseDelay.inMilliseconds * (1 << exponent);
    return Duration(
      milliseconds: millis > recoveryMaxDelay.inMilliseconds
          ? recoveryMaxDelay.inMilliseconds
          : millis,
    );
  }

  Future<void> _recoverPlayback(
    String failMessage, {
    bool reloadCurrentUrl = true,
  }) async {
    _reportedPlaying = false;
    _stablePlaybackTimer?.cancel();
    if (isClosed ||
        !liveStatus.value ||
        _automaticRecoveryExhausted ||
        _recoveringPlayback) {
      return;
    }
    var now = DateTime.now();
    var last = _lastRecoveryEventAt;
    if (last != null && now.difference(last) < recoveryBurstWindow) {
      return;
    }
    _lastRecoveryEventAt = now;
    var generation = _recoveryGeneration;
    _recoveringPlayback = true;
    try {
      if (reloadCurrentUrl &&
          !_awaitingStablePlayback &&
          mediaErrorRetryCount < 1) {
        mediaErrorRetryCount++;
        recoveryStatus.value = "正在重连";
        DiagnosticService.instance.recordRecovery('重载当前线路');
        await setPlayer();
        return;
      }
      await retryWithFreshUrls(failMessage, generation);
    } catch (e) {
      Log.logPrint(e);
      if (generation == _recoveryGeneration) {
        await retryWithFreshUrls(failMessage, generation);
      }
    } finally {
      if (generation == _recoveryGeneration) {
        _recoveringPlayback = false;
      }
    }
  }

  Future<void> retryWithFreshUrls(
    String failMessage,
    int generation,
  ) async {
    if (generation != _recoveryGeneration || isClosed || !liveStatus.value) {
      return;
    }
    if (_freshUrlAttempts >= _maxFreshUrlAttempts) {
      _automaticRecoveryExhausted = true;
      _awaitingStablePlayback = false;
      errorMsg.value = failMessage;
      recoveryStatus.value = "自动恢复停止，按确认键重试";
      DiagnosticService.instance.recordRecovery('自动恢复停止');
      SmartDialog.showToast("$failMessage，自动恢复已停止，请手动刷新");
      return;
    }
    _freshUrlAttempts++;
    recoveryStatus.value = "切换线路（$_freshUrlAttempts/$_maxFreshUrlAttempts）";
    DiagnosticService.instance.recordRecovery(
      '重新获取地址 $_freshUrlAttempts/$_maxFreshUrlAttempts',
    );
    if (_freshUrlAttempts > 1) {
      await Future.delayed(recoveryDelayFor(_freshUrlAttempts));
    }
    if (generation != _recoveryGeneration || isClosed) {
      return;
    }

    bool ok;
    try {
      ok = await getPlayUrl(
        notifyError: false,
        resetRecovery: false,
        recoveryGeneration: generation,
      );
    } catch (e) {
      Log.logPrint(e);
      ok = false;
    }
    if (!ok) {
      // 取址接口失败并不等于平台明确报告下播。
      await retryWithFreshUrls(failMessage, generation);
      return;
    }
    _awaitingStablePlayback = true;
  }

  void _resetRecoveryState() {
    _recoveryGeneration++;
    _stablePlaybackTimer?.cancel();
    _reportedPlaying = false;
    mediaErrorRetryCount = 0;
    _freshUrlAttempts = 0;
    _awaitingStablePlayback = false;
    _automaticRecoveryExhausted = false;
    _recoveringPlayback = false;
    _lastRecoveryEventAt = null;
    recoveryStatus.value = "";
    errorMsg.value = "";
  }

  @override
  void onPlayingChanged(bool playing) {
    _reportedPlaying = playing;
    _stablePlaybackTimer?.cancel();
    if (!playing || isClosed) {
      return;
    }
    _stablePlaybackTimer = Timer(stablePlaybackDuration, () {
      if (_reportedPlaying && !isClosed) {
        DiagnosticService.instance.recordRecovery('播放稳定');
        _resetRecoveryState();
      }
    });
  }

  /// 添加历史记录
  void addHistory() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    var history = DBService.instance.getHistory(id);
    if (history != null) {
      history.updateTime = DateTime.now();
    }
    history ??= History(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: detail.value?.userName ?? "",
      face: detail.value?.userAvatar ?? "",
      updateTime: DateTime.now(),
    );

    DBService.instance.addOrUpdateHistory(history);
  }

  /// 关注用户
  void followUser() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    DBService.instance.addFollow(
      FollowUser(
        id: id,
        roomId: roomId,
        siteId: site.id,
        userName: detail.value?.userName ?? "",
        face: detail.value?.userAvatar ?? "",
        addTime: DateTime.now(),
      ),
    );
    followed.value = true;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
    SmartDialog.showToast("已关注");
  }

  /// 取消关注用户
  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    // if (!await Utils.showAlertDialog("确定要取消关注该用户吗？", title: "取消关注")) {
    //   return;
    // }

    var id = "${site.id}_$roomId";
    DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
    SmartDialog.showToast("已取消关注");
  }

  void resetRoom(Site site, String roomId) async {
    if (this.site == site && this.roomId == roomId) {
      return;
    }

    rxSite.value = site;
    rxRoomId.value = roomId;
    _resetRecoveryState();

    // 清除全部消息
    liveDanmaku.stop();

    danmakuController?.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();

    // 停止播放
    await player.stop();

    // 刷新信息
    loadData();
  }

  void nextChannel() {
    //读取正在直播的频道
    var liveChannels = FollowUserService.instance.livingList;
    if (liveChannels.isEmpty) {
      SmartDialog.showToast("没有正在直播的频道");
      return;
    }
    var index = liveChannels.indexWhere(
      (element) => element.id == "${site.id}_$roomId",
    );
    // if (index == -1) {
    //   //当前频道不在列表中

    //   return;
    // }
    index += 1;
    if (index >= liveChannels.length) {
      index = 0;
    }
    var nextChannel = liveChannels[index];

    resetRoom(Sites.allSites[nextChannel.siteId]!, nextChannel.roomId);
  }

  void prevChannel() {
    //读取正在直播的频道
    var liveChannels = FollowUserService.instance.livingList;
    if (liveChannels.isEmpty) {
      SmartDialog.showToast("没有正在直播的频道");
      return;
    }
    var index = liveChannels.indexWhere(
      (element) => element.id == "${site.id}_$roomId",
    );
    // if (index == -1) {
    //   //当前频道不在列表中

    //   return;
    // }
    index -= 1;
    if (index < 0) {
      index = liveChannels.length - 1;
    }
    var nextChannel = liveChannels[index];

    resetRoom(Sites.allSites[nextChannel.siteId]!, nextChannel.roomId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      Log.d("进入后台");
      //进入后台，关闭弹幕
      danmakuController?.clear();
      isBackground = true;
    } else
    //返回前台
    if (state == AppLifecycleState.resumed) {
      Log.d("返回前台");
      isBackground = false;
    }
  }

  @override
  void onClose() {
    _stablePlaybackTimer?.cancel();
    liveDanmaku.stop();

    danmakuController = null;
    super.onClose();
  }
}
