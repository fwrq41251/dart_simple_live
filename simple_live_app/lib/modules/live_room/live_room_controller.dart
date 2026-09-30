import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_app/modules/settings/danmu_settings_page.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/desktop_refresh_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class LiveRoomController extends PlayerController with WidgetsBindingObserver {
  final Site pSite;
  final String pRoomId;
  late LiveDanmaku liveDanmaku;
  LiveRoomController({
    required this.pSite,
    required this.pRoomId,
  }) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    liveDanmaku = site.liveSite.getDanmaku();
    // 抖音应该默认是竖屏的
    if (site.id == "douyin") {
      isVertical.value = true;
    }
  }

  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  var liveStatus = false.obs;
  RxList<LiveSuperChatMessage> superChats = RxList<LiveSuperChatMessage>();

  /// 滚动控制
  final ScrollController scrollController = ScrollController();

  /// 聊天信息
  RxList<LiveMessage> messages = RxList<LiveMessage>();

  /// 聊天列表绝对上限。上滚暂停自动滚动时不裁剪，但超过此值强制裁剪，
  /// 避免长时间挂机导致列表无限增长。
  static const int _maxMessages = 500;

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

  /// 退出倒计时
  var countdown = 60.obs;

  Timer? autoExitTimer;

  /// 设置的自动关闭时间（分钟）
  var autoExitMinutes = 60.obs;

  ///是否延迟自动关闭
  var delayAutoExit = false.obs;

  /// 是否启用自动关闭
  var autoExitEnable = false.obs;

  /// 是否禁用自动滚动聊天栏
  /// - 当用户向上滚动聊天栏时，不再自动滚动
  var disableAutoScroll = false.obs;

  /// 是否处于后台
  var isBackground = false;

  /// 进入回放列表后暂停直播，避免两个播放器同时输出音频。
  bool _replaySuspended = false;
  int _playbackGeneration = 0;

  bool _isCurrentPlaybackGeneration(int generation) =>
      generation == _playbackGeneration && !_replaySuspended && !isClosed;

  /// 直播间加载失败
  var loadError = false.obs;
  Object? error;

  // 开播时长状态变量
  var liveDuration = "00:00:00".obs;
  Timer? _liveDurationTimer;

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    if (FollowService.instance.followList.isEmpty) {
      FollowService.instance.loadData();
    }
    initAutoExit();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
    loadData();

    scrollController.addListener(scrollListener);

    super.onInit();
  }

  void scrollListener() {
    if (scrollController.position.userScrollDirection ==
        ScrollDirection.forward) {
      disableAutoScroll.value = true;
    }
  }

  /// 初始化自动关闭倒计时
  void initAutoExit() {
    if (AppSettingsController.instance.autoExitEnable.value) {
      autoExitEnable.value = true;
      autoExitMinutes.value =
          AppSettingsController.instance.autoExitDuration.value;
      setAutoExit();
    } else {
      autoExitMinutes.value =
          AppSettingsController.instance.roomAutoExitDuration.value;
    }
  }

  void setAutoExit() {
    if (!autoExitEnable.value) {
      autoExitTimer?.cancel();
      return;
    }
    autoExitTimer?.cancel();
    countdown.value = autoExitMinutes.value * 60;
    autoExitTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      countdown.value -= 1;
      if (countdown.value <= 0) {
        timer = Timer(const Duration(seconds: 10), () async {
          await WakelockPlus.disable();
          SystemNavigator.pop();
        });
        autoExitTimer?.cancel();
        var delay = await Utils.showAlertDialog("定时关闭已到时,是否延迟关闭?",
            title: "延迟关闭", confirm: "延迟", cancel: "关闭", selectable: true);
        if (delay) {
          timer.cancel();
          delayAutoExit.value = true;
          showAutoExitSheet();
          setAutoExit();
        } else {
          delayAutoExit.value = false;
          await WakelockPlus.disable();
          SystemNavigator.pop();
        }
      }
    });
  }
  // 弹窗逻辑

  void refreshRoom() {
    _resetRecoveryState();
    //messages.clear();
    superChats.clear();
    liveDanmaku.stop();

    loadData();
  }

  /// 聊天栏始终滚动到底部
  void chatScrollToBottom() {
    if (scrollController.hasClients) {
      // 如果手动上拉过，就不自动滚动到底部
      if (disableAutoScroll.value) {
        return;
      }
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
    }
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    liveDanmaku.onMessage = onWSMessage;
    liveDanmaku.onClose = onWSClose;
    liveDanmaku.onReady = onWSReady;
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (msg.type == LiveMessageType.chat) {
      if (messages.length > 200 && !disableAutoScroll.value) {
        messages.removeAt(0);
      }
      // 上滚时不裁剪是为了避免列表内容在用户阅读时跳动，
      // 但必须有绝对上限，否则长时间挂机会无限增长。
      // 裁剪发生在 add 之前，故用 >= 保证最终长度不超过 _maxMessages。
      if (messages.length >= _maxMessages) {
        messages.removeRange(0, messages.length - _maxMessages + 1);
      }

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

      messages.add(msg);

      WidgetsBinding.instance.addPostFrameCallback(
        (_) => chatScrollToBottom(),
      );
      if (!liveStatus.value || isBackground) {
        return;
      }

      addDanmaku([
        DanmakuContentItem(
          msg.message,
          color: Color.fromARGB(
            255,
            msg.color.r,
            msg.color.g,
            msg.color.b,
          ),
        ),
      ]);
    } else if (msg.type == LiveMessageType.online) {
      online.value = msg.data;
    } else if (msg.type == LiveMessageType.superChat) {
      superChats.add(msg.data);
    }
  }

  /// 添加一条系统消息
  void addSysMsg(String msg) {
    messages.add(
      LiveMessage(
        type: LiveMessageType.chat,
        userName: "LiveSysMessage",
        message: msg,
        color: LiveMessageColor.white,
      ),
    );
  }

  /// 接收到WebSocket关闭信息
  void onWSClose(String msg) {
    addSysMsg(msg);
  }

  /// WebSocket准备就绪
  void onWSReady() {
    addSysMsg("弹幕服务器连接正常");
  }

  /// 加载直播间信息
  void loadData() async {
    var generation = ++_playbackGeneration;
    try {
      SmartDialog.showLoading(msg: "");
      loadError.value = false;
      error = null;
      update();
      addSysMsg("正在读取直播间信息");
      var roomDetail = await site.liveSite.getRoomDetail(roomId: roomId);
      if (!_isCurrentPlaybackGeneration(generation)) {
        return;
      }
      detail.value = roomDetail;
      if (site.id == Constant.kDouyin) {
        // 1.6.0之前收藏的WebRid
        // 1.6.0收藏的RoomID
        // 1.6.0之后改回WebRid
        if (detail.value!.roomId != roomId) {
          var oldId = roomId;
          rxRoomId.value = detail.value!.roomId;
          if (followed.value) {
            // 更新关注列表
            DBService.instance.deleteFollow("${site.id}_$oldId");
            DBService.instance.addFollow(
              FollowUser(
                id: "${site.id}_$roomId",
                roomId: roomId,
                siteId: site.id,
                userName: detail.value!.userName,
                face: detail.value!.userAvatar,
                addTime: DateTime.now(),
              ),
            );
          } else {
            followed.value =
                DBService.instance.getFollowExist("${site.id}_$roomId");
          }
        }
      }

      getSuperChatMessage();

      addHistory();
      // 确认房间关注状态
      followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      if (liveStatus.value && !_replaySuspended) {
        getPlayQualites();
      }
      if (detail.value!.isRecord) {
        addSysMsg("当前主播未开播，正在轮播录像");
      }
      if (!_replaySuspended) {
        addSysMsg("开始连接弹幕服务器");
        initDanmau();
        liveDanmaku.start(detail.value?.danmakuData);
      }
      startLiveDurationTimer(); // 启动开播时长定时器
    } catch (e) {
      if (generation != _playbackGeneration) {
        return;
      }
      Log.logPrint(e);
      //SmartDialog.showToast(e.toString());
      loadError.value = true;
      error = e;
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  /// 初始化播放器
  Future<void> getPlayQualites() async {
    var generation = _playbackGeneration;
    qualites.clear();
    currentQuality = -1;

    try {
      var playQualites =
          await site.liveSite.getPlayQualites(detail: detail.value!);
      if (!_isCurrentPlaybackGeneration(generation)) {
        return;
      }

      if (playQualites.isEmpty) {
        SmartDialog.showToast("无法读取播放清晰度");
        return;
      }
      qualites.value = playQualites;
      var qualityLevel = await getQualityLevel();
      if (!_isCurrentPlaybackGeneration(generation)) {
        return;
      }
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

      await getPlayUrl();
    } catch (e) {
      if (_isCurrentPlaybackGeneration(generation)) {
        Log.logPrint(e);
        SmartDialog.showToast("无法读取播放清晰度");
      }
    }
  }

  Future<int> getQualityLevel() async {
    var qualityLevel = AppSettingsController.instance.qualityLevel.value;
    try {
      var connectivityResult = await (Connectivity().checkConnectivity());
      if (connectivityResult.first == ConnectivityResult.mobile) {
        qualityLevel =
            AppSettingsController.instance.qualityLevelCellular.value;
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return qualityLevel;
  }

  Future<bool> getPlayUrl({
    bool notifyError = true,
    bool resetRecovery = true,
  }) async {
    if (resetRecovery) {
      _resetRecoveryState();
    }
    var generation = _playbackGeneration;
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
    var playUrl = await site.liveSite
        .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
    if (!_isCurrentPlaybackGeneration(generation)) {
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
    //重置错误次数
    mediaErrorRetryCount = 0;
    await initPlaylist();
    return _isCurrentPlaybackGeneration(generation);
  }

  Future<void> changePlayLine(int index) async {
    _resetRecoveryState();
    currentLineIndex = index;
    await setPlayer();
  }

  Future<void> initPlaylist() async {
    var generation = _playbackGeneration;
    if (!_isCurrentPlaybackGeneration(generation)) {
      return;
    }
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";

    final mediaList = playUrls.map((url) {
      var finalUrl = url;
      if (AppSettingsController.instance.playerForceHttps.value) {
        finalUrl = finalUrl.replaceAll("http://", "https://");
      }
      return Media(finalUrl, httpHeaders: playHeaders);
    }).toList();

    // 初始化播放器并设置 ao 参数
    await initializePlayer();
    if (!_isCurrentPlaybackGeneration(generation)) {
      return;
    }

    await player.open(Playlist(mediaList));
  }

  Future<void> setPlayer() async {
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";

    await player.jump(currentLineIndex);
  }

  @override
  void mediaEnd() {
    super.mediaEnd();
    unawaited(_recoverPlayback("播放结束"));
  }

  int mediaErrorRetryCount = 0;

  @override
  void mediaError(String error) {
    super.mediaError(error);
    unawaited(_recoverPlayback("播放失败:$error"));
  }

  /// 同一断流只允许一个恢复流程，避免 error/completed 重复触发重开。
  bool _recoveringPlayback = false;
  bool _awaitingStablePlayback = false;
  bool _automaticRecoveryExhausted = false;
  bool _reportedPlaying = false;
  Timer? _stablePlaybackTimer;
  int _freshUrlAttempts = 0;
  static const int _maxFreshUrlAttempts = 3;

  /// 上一次处理断流事件的时间，用于折叠同一波断流。
  DateTime? _lastRecoveryEventAt;

  /// 缓冲看门狗：区分「网络抖动，mpv 正在自愈」与「地址真的失效」。
  ///
  /// mpv 开启 stream-lavf-o 重连后，短暂抖动不再抛 error，而是进入
  /// paused-for-cache。此时重建播放链路只会打断本来能自愈的连接，所以先等；
  /// 只有持续缓冲超过 watchdog 时限，才认定地址失效并升级到换地址。
  Timer? _bufferingWatchdog;
  DateTime? _bufferingSince;
  bool _bufferingActive = false;

  /// 缓冲持续多久后认定地址失效。需大于 mpv 单次重连等待上限（5s），
  /// 否则会在 mpv 自愈前抢先重建。
  @protected
  Duration get bufferingWatchdogTimeout => const Duration(seconds: 12);

  @protected
  Duration get stablePlaybackDuration => const Duration(seconds: 10);

  /// 重试退避的基准间隔（斗鱼网页端同样以 1s 起步）。
  @protected
  Duration get recoveryBaseDelay => const Duration(milliseconds: 500);

  /// 退避上限，避免长时间断流后等待过久（对齐斗鱼网页端的 30s 上限）。
  @protected
  Duration get recoveryMaxDelay => const Duration(seconds: 30);

  /// 同一波断流的合并窗口：窗口内的重复事件视为同一次中断。
  ///
  /// 播放器在一次中断里会连续抛出多个事件（error、completed、以及换线路后
  /// 新地址尚未就绪时的再次 error）。斗鱼网页端用 throttle 折叠这些调用，
  /// 这里用时间窗口达到同样效果，避免同一波断流被重放多次。
  @protected
  Duration get recoveryBurstWindow => const Duration(milliseconds: 800);

  /// 指数退避：第 n 次重试等待 base * 2^(n-1)，封顶 recoveryMaxDelay。
  Duration recoveryDelayFor(int attempt) {
    var exponent = attempt <= 1 ? 0 : attempt - 1;
    var millis = recoveryBaseDelay.inMilliseconds * (1 << exponent);
    var capped = millis > recoveryMaxDelay.inMilliseconds
        ? recoveryMaxDelay.inMilliseconds
        : millis;
    return Duration(milliseconds: capped);
  }

  Future<void> _recoverPlayback(String failMessage) async {
    _reportedPlaying = false;
    _stablePlaybackTimer?.cancel();
    if (_replaySuspended ||
        isClosed ||
        !liveStatus.value ||
        _automaticRecoveryExhausted ||
        _recoveringPlayback) {
      return;
    }

    // 同一波断流只处理一次：播放器会连抛多个事件，
    // 若逐个处理，一次断流会触发多轮换线/换地址。
    var now = DateTime.now();
    var last = _lastRecoveryEventAt;
    if (last != null && now.difference(last) < recoveryBurstWindow) {
      Log.d("同一波断流，忽略重复事件");
      return;
    }
    _lastRecoveryEventAt = now;

    var generation = _playbackGeneration;
    _recoveringPlayback = true;
    try {
      // 第一级：原地重载当前线路一次。mpv 层已开启 HTTP 重连，能自愈的
      // 抖动不会走到这里；走到这里说明连接确实断了，重载一次仍值得尝试。
      if (!_awaitingStablePlayback && mediaErrorRetryCount < 1) {
        mediaErrorRetryCount += 1;
        Log.d("播放中断，重载当前线路");
        await setPlayer();
        return;
      }

      // 第二级：重新向平台请求地址。斗鱼地址带时效签名，签名过期后换线路
      // 拿到的仍是同一个失效签名，只有重新取址才有意义。
      await retryWithFreshUrls(failMessage, generation);
    } catch (e) {
      Log.logPrint(e);
      if (_isCurrentPlaybackGeneration(generation)) {
        await retryWithFreshUrls(failMessage, generation);
      }
    } finally {
      _recoveringPlayback = false;
    }
  }

  /// 旧地址与所有线路均失效后，重新向平台请求播放地址。
  Future<void> retryWithFreshUrls(
    String failMessage,
    int generation,
  ) async {
    if (!_isCurrentPlaybackGeneration(generation)) {
      return;
    }
    if (_freshUrlAttempts >= _maxFreshUrlAttempts) {
      _automaticRecoveryExhausted = true;
      _awaitingStablePlayback = false;
      errorMsg.value = failMessage;
      SmartDialog.showToast("$failMessage，自动恢复已停止，请手动刷新");
      return;
    }

    _freshUrlAttempts += 1;
    Log.d("播放地址可能已失效，重新获取（第$_freshUrlAttempts/$_maxFreshUrlAttempts 次）");
    if (_freshUrlAttempts > 1) {
      await Future.delayed(recoveryDelayFor(_freshUrlAttempts));
    }
    if (!_isCurrentPlaybackGeneration(generation)) {
      return;
    }

    bool ok;
    try {
      ok = await getPlayUrl(
        notifyError: false,
        resetRecovery: false,
      );
    } catch (e) {
      Log.logPrint(e);
      ok = false;
    }
    if (!ok) {
      _resetRecoveryState();
      liveStatus.value = false;
      return;
    }

    // playing=true 可能只是 open/jump 的瞬时事件；稳定计时结束前不清空重试状态。
    _awaitingStablePlayback = true;
  }

  void _resetRecoveryState() {
    _stablePlaybackTimer?.cancel();
    _bufferingWatchdog?.cancel();
    _bufferingActive = false;
    _bufferingSince = null;
    _reportedPlaying = false;
    mediaErrorRetryCount = 0;
    _freshUrlAttempts = 0;
    _awaitingStablePlayback = false;
    _automaticRecoveryExhausted = false;
    _lastRecoveryEventAt = null;
  }

  @override
  void onPlayingChanged(bool playing) {
    _reportedPlaying = playing;
    _stablePlaybackTimer?.cancel();
    if (!playing || _replaySuspended || isClosed) {
      return;
    }
    _stablePlaybackTimer = Timer(stablePlaybackDuration, () {
      if (_reportedPlaying && !_replaySuspended && !isClosed) {
        Log.d("播放已稳定，重置断流恢复状态");
        _resetRecoveryState();
      }
    });
  }

  /// mpv 缓冲状态变化。由 PlayerController 的 buffering 流驱动。
  ///
  /// 进入缓冲时启动看门狗：mpv 若在时限内自愈（恢复播放），什么都不做，
  /// 画面不重建；超时则说明地址失效，升级到换新地址。
  @override
  void onBufferingChanged(bool buffering) {
    if (_replaySuspended || isClosed || !liveStatus.value) {
      return;
    }
    _bufferingActive = buffering;
    _bufferingWatchdog?.cancel();
    if (!buffering) {
      _bufferingSince = null;
      return;
    }

    _bufferingSince = DateTime.now();
    Log.d("播放缓冲中，等待 mpv 自愈");
    _bufferingWatchdog = Timer(bufferingWatchdogTimeout, () {
      if (!_bufferingActive || _replaySuspended || isClosed) {
        return;
      }
      var since = _bufferingSince;
      if (since == null ||
          DateTime.now().difference(since) < bufferingWatchdogTimeout) {
        return;
      }
      Log.d("缓冲超时，判定播放地址失效");
      // 先清掉缓冲态，否则升级过程中新事件会被自身的看门狗逻辑干扰
      _bufferingActive = false;
      _bufferingSince = null;
      unawaited(_recoverPlayback("播放地址失效"));
    });
  }

  /// 读取SC
  void getSuperChatMessage() async {
    try {
      var sc =
          await site.liveSite.getSuperChatMessage(roomId: detail.value!.roomId);
      superChats.addAll(sc);
    } catch (e) {
      Log.logPrint(e);
      addSysMsg("SC读取失败");
    }
  }

  /// 移除掉已到期的SC
  void removeSuperChats() async {
    var now = DateTime.now().millisecondsSinceEpoch;
    superChats.value = superChats
        .where((x) => x.endTime.millisecondsSinceEpoch > now)
        .toList();
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
  }

  /// 取消关注用户
  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    if (!await Utils.showAlertDialog("确定要取消关注该用户吗？", title: "取消关注")) {
      return;
    }

    var id = "${site.id}_$roomId";
    var user = FollowUser(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: detail.value?.userName ?? "",
      face: detail.value?.userAvatar ?? "",
      addTime: DateTime.now(),
    );
    DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);

    ScaffoldMessenger.of(Get.context!).showSnackBar(
      SnackBar(
        content: Text("已取消关注 ${user.userName}"),
        action: SnackBarAction(
          label: "撤销",
          onPressed: () {
            DBService.instance.addFollow(user);
            followed.value = true;
            EventBus.instance.emit(Constant.kUpdateFollow, id);
          },
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void share() {
    if (detail.value == null) {
      return;
    }
    SharePlus.instance.share(ShareParams(uri: Uri.parse(detail.value!.url)));
  }

  void copyUrl() {
    if (detail.value == null) {
      return;
    }
    Utils.copyToClipboard(detail.value!.url);
    SmartDialog.showToast("已复制直播间链接");
  }

  /// 复制新生成的直播流
  void copyPlayUrl() async {
    // 未开播不复制
    if (!liveStatus.value) {
      return;
    }
    var playUrl = await site.liveSite
        .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
    if (playUrl.urls.isEmpty) {
      SmartDialog.showToast("无法读取播放地址");
      return;
    }
    Utils.copyToClipboard(playUrl.urls.first);
    SmartDialog.showToast("已复制播放直链");
  }

  /// 底部打开播放器设置
  void showDanmuSettingsSheet() {
    Utils.showBottomSheet(
      title: "弹幕设置",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          DanmuSettingsView(
            danmakuController: danmakuController,
            onTapDanmuShield: () {
              Get.back();
              showDanmuShield();
            },
          ),
        ],
      ),
    );
  }

  void showVolumeSlider(BuildContext targetContext) {
    SmartDialog.showAttach(
      targetContext: targetContext,
      alignment: Alignment.topCenter,
      displayTime: const Duration(seconds: 3),
      maskColor: const Color(0x00000000),
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: AppStyle.radius12,
            color: Theme.of(context).cardColor,
          ),
          padding: AppStyle.edgeInsetsA4,
          child: Obx(
            () => SizedBox(
              width: 200,
              child: Slider(
                min: 0,
                max: 100,
                value: AppSettingsController.instance.playerVolume.value,
                onChanged: (newValue) {
                  player.setVolume(newValue);
                  AppSettingsController.instance.setPlayerVolume(newValue);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void showQualitySheet() {
    Utils.showBottomSheet(
      title: "切换清晰度",
      child: RadioGroup(
        groupValue: currentQuality,
        onChanged: (e) {
          Get.back();
          currentQuality = e ?? 0;
          getPlayUrl();
        },
        child: ListView.builder(
          itemCount: qualites.length,
          itemBuilder: (_, i) {
            var item = qualites[i];
            return RadioListTile(
              value: i,
              title: Text(item.quality),
            );
          },
        ),
      ),
    );
  }

  void showPlayUrlsSheet() {
    Utils.showBottomSheet(
      title: "切换线路",
      child: RadioGroup(
        groupValue: currentLineIndex,
        onChanged: (e) {
          Get.back();
          //currentLineIndex = i;
          //setPlayer();
          changePlayLine(e ?? 0);
        },
        child: ListView.builder(
          itemCount: playUrls.length,
          itemBuilder: (_, i) {
            return RadioListTile(
              value: i,
              title: Text("线路${i + 1}"),
              secondary: Text(
                playUrls[i].contains(".flv") ? "FLV" : "HLS",
              ),
            );
          },
        ),
      ),
    );
  }

  void showPlayerSettingsSheet() {
    Utils.showBottomSheet(
      title: "画面尺寸",
      child: Obx(
        () => RadioGroup(
          groupValue: AppSettingsController.instance.scaleMode.value,
          onChanged: (e) {
            AppSettingsController.instance.setScaleMode(e ?? 0);
            updateScaleMode();
          },
          child: ListView(
            padding: AppStyle.edgeInsetsV12,
            children: const [
              RadioListTile(
                value: 0,
                title: Text("适应"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 1,
                title: Text("拉伸"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 2,
                title: Text("铺满"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 3,
                title: Text("16:9"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 4,
                title: Text("4:3"),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showDanmuShield() {
    TextEditingController keywordController = TextEditingController();

    void addKeyword() {
      if (keywordController.text.isEmpty) {
        SmartDialog.showToast("请输入关键词");
        return;
      }

      AppSettingsController.instance
          .addShieldList(keywordController.text.trim());
      keywordController.text = "";
    }

    Utils.showBottomSheet(
      title: "关键词屏蔽",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          TextField(
            controller: keywordController,
            decoration: InputDecoration(
              contentPadding: AppStyle.edgeInsetsH12,
              border: const OutlineInputBorder(),
              hintText: "请输入关键词",
              suffixIcon: TextButton.icon(
                onPressed: addKeyword,
                icon: const Icon(Icons.add),
                label: const Text("添加"),
              ),
            ),
            onSubmitted: (e) {
              addKeyword();
            },
          ),
          AppStyle.vGap12,
          Obx(
            () => Text(
              "已添加${AppSettingsController.instance.shieldList.length}个关键词（点击移除）",
              style: Get.textTheme.titleSmall,
            ),
          ),
          AppStyle.vGap12,
          Obx(
            () => Wrap(
              runSpacing: 12,
              spacing: 12,
              children: AppSettingsController.instance.shieldList
                  .map(
                    (item) => InkWell(
                      borderRadius: AppStyle.radius24,
                      onTap: () {
                        AppSettingsController.instance.removeShieldList(item);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: AppStyle.radius24,
                        ),
                        padding: AppStyle.edgeInsetsH12.copyWith(
                          top: 4,
                          bottom: 4,
                        ),
                        child: Text(
                          item,
                          style: Get.textTheme.bodyMedium,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  void showFollowUserSheet() {
    Utils.showBottomSheet(
      title: "关注列表",
      child: Obx(
        () => Stack(
          children: [
            RefreshIndicator(
              onRefresh: FollowService.instance.loadData,
              child: ListView.builder(
                itemCount: FollowService.instance.liveList.length,
                itemBuilder: (_, i) {
                  var item = FollowService.instance.liveList[i];
                  return Obx(
                    () => FollowUserItem(
                      item: item,
                      playing: rxSite.value.id == item.siteId &&
                          rxRoomId.value == item.roomId,
                      onTap: () {
                        Get.back();
                        resetRoom(
                          Sites.allSites[item.siteId]!,
                          item.roomId,
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            if (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
              Positioned(
                right: 12,
                bottom: 12,
                child: Obx(
                  () => DesktopRefreshButton(
                    refreshing: FollowService.instance.updating.value,
                    onPressed: FollowService.instance.loadData,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void showAutoExitSheet() {
    if (AppSettingsController.instance.autoExitEnable.value &&
        !delayAutoExit.value) {
      SmartDialog.showToast("已设置了全局定时关闭");
      return;
    }
    Utils.showBottomSheet(
      title: "定时关闭",
      child: ListView(
        children: [
          Obx(
            () => SwitchListTile(
              title: Text(
                "启用定时关闭",
                style: Get.textTheme.titleMedium,
              ),
              value: autoExitEnable.value,
              onChanged: (e) {
                autoExitEnable.value = e;

                setAutoExit();
                //controller.setAutoExitEnable(e);
              },
            ),
          ),
          Obx(
            () => ListTile(
              enabled: autoExitEnable.value,
              title: Text(
                "自动关闭时间：${autoExitMinutes.value ~/ 60}小时${autoExitMinutes.value % 60}分钟",
                style: Get.textTheme.titleMedium,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                var value = await showTimePicker(
                  context: Get.context!,
                  initialTime: TimeOfDay(
                    hour: autoExitMinutes.value ~/ 60,
                    minute: autoExitMinutes.value % 60,
                  ),
                  initialEntryMode: TimePickerEntryMode.inputOnly,
                  builder: (_, child) {
                    return MediaQuery(
                      data: Get.mediaQuery.copyWith(
                        alwaysUse24HourFormat: true,
                      ),
                      child: child!,
                    );
                  },
                );
                if (value == null || (value.hour == 0 && value.minute == 0)) {
                  return;
                }
                var duration =
                    Duration(hours: value.hour, minutes: value.minute);
                autoExitMinutes.value = duration.inMinutes;
                AppSettingsController.instance
                    .setRoomAutoExitDuration(autoExitMinutes.value);
                //setAutoExitDuration(duration.inMinutes);
                setAutoExit();
              },
            ),
          ),
        ],
      ),
    );
  }

  void openNaviteAPP() async {
    var naviteUrl = "";
    var webUrl = "";
    if (site.id == Constant.kBiliBili) {
      naviteUrl = "bilibili://live/${detail.value?.roomId}";
      webUrl = "https://live.bilibili.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyin) {
      var args = detail.value?.danmakuData as DouyinDanmakuArgs;
      naviteUrl = "snssdk1128://webcast_room?room_id=${args.roomId}";
      webUrl = "https://live.douyin.com/${args.webRid}";
    } else if (site.id == Constant.kHuya) {
      var args = detail.value?.danmakuData as HuyaDanmakuArgs;
      naviteUrl =
          "yykiwi://homepage/index.html?banneraction=https%3A%2F%2Fdiy-front.cdn.huya.com%2Fzt%2Ffrontpage%2Fcc%2Fupdate.html%3Fhyaction%3Dlive%26channelid%3D${args.subSid}%26subid%3D${args.subSid}%26liveuid%3D${args.subSid}%26screentype%3D1%26sourcetype%3D0%26fromapp%3Dhuya_wap%252Fclick%252Fopen_app_guide%26&fromapp=huya_wap/click/open_app_guide";
      webUrl = "https://www.huya.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyu) {
      naviteUrl =
          "douyulink://?type=90001&schemeUrl=douyuapp%3A%2F%2Froom%3FliveType%3D0%26rid%3D${detail.value?.roomId}";
      webUrl = "https://www.douyu.com/${detail.value?.roomId}";
    }
    try {
      await launchUrlString(naviteUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法打开APP，将使用浏览器打开");
      await launchUrlString(webUrl, mode: LaunchMode.externalApplication);
    }
  }

  /// 暂停直播播放器与弹幕连接，直到回放列表关闭。
  @protected
  Future<void> stopPlayerForReplay() => player.stop();

  Future<void> suspendForReplay() async {
    if (_replaySuspended) {
      return;
    }
    _replaySuspended = true;
    _resetRecoveryState();
    _playbackGeneration++;
    liveDanmaku.stop();
    await stopPlayerForReplay();
    await WakelockPlus.disable();
  }

  /// 从回放列表返回直播间后恢复直播播放器与弹幕。
  Future<void> resumeAfterReplay() async {
    if (!_replaySuspended || isClosed) {
      return;
    }
    _replaySuspended = false;

    if (detail.value == null) {
      loadData();
      return;
    }

    initDanmau();
    liveDanmaku.start(detail.value?.danmakuData);
    if (!liveStatus.value) {
      return;
    }
    if (qualites.isEmpty) {
      await getPlayQualites();
    } else {
      await getPlayUrl();
    }
  }

  void resetRoom(Site site, String roomId) async {
    if (this.site == site && this.roomId == roomId) {
      return;
    }

    _resetRecoveryState();
    rxSite.value = site;
    rxRoomId.value = roomId;
    _playbackGeneration++;

    // 清除全部消息
    liveDanmaku.stop();
    messages.clear();
    superChats.clear();
    danmakuController?.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();

    // 停止播放
    await player.stop();

    // 刷新信息
    loadData();
  }

  void copyErrorDetail() {
    Utils.copyToClipboard('''直播平台：${rxSite.value.name}
房间号：${rxRoomId.value}
错误信息：
${error?.toString()}
----------------
''');
    SmartDialog.showToast("已复制错误信息");
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

  // 用于启动开播时长计算和更新的函数
  void startLiveDurationTimer() {
    // 如果不是直播状态或者 showTime 为空，则不启动定时器
    if (!(detail.value?.status ?? false) || detail.value?.showTime == null) {
      liveDuration.value = "00:00:00"; // 未开播时显示 00:00:00
      _liveDurationTimer?.cancel();
      return;
    }

    try {
      int startTimeStamp = int.parse(detail.value!.showTime!);
      // 取消之前的定时器
      _liveDurationTimer?.cancel();
      // 创建新的定时器，每秒更新一次
      _liveDurationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        int durationInSeconds = currentTimeStamp - startTimeStamp;

        int hours = durationInSeconds ~/ 3600;
        int minutes = (durationInSeconds % 3600) ~/ 60;
        int seconds = durationInSeconds % 60;

        String formattedDuration =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
        liveDuration.value = formattedDuration;
      });
    } catch (e) {
      liveDuration.value = "--:--:--"; // 错误时显示 --:--:--
    }
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    scrollController.removeListener(scrollListener);
    autoExitTimer?.cancel();
    _stablePlaybackTimer?.cancel();
    _bufferingWatchdog?.cancel();
    _replaySuspended = true;

    liveDanmaku.stop();
    danmakuController = null;
    _liveDurationTimer?.cancel(); // 页面关闭时取消定时器
    super.onClose();
  }
}
