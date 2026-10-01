// 验证重试逻辑：播放地址失效 vs 房间确实下播
// 对应修复：重试计数用尽后重新获取播放地址，而不是直接判定未开播。
// ignore_for_file: must_call_super
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// 假站点：urlsAvailable=false 模拟播放地址接口暂时不可用。
class FakeSite extends LiveSite {
  FakeSite({required this.urlsAvailable});
  final bool urlsAvailable;
  int fetchCount = 0;
  int detailFetchCount = 0;
  Completer<LivePlayUrl>? pendingPlayUrl;

  @override
  String get id => "douyu";
  @override
  String get name => "fake";

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    detailFetchCount++;
    return LiveRoomDetail(
      roomId: roomId,
      title: 't',
      cover: '',
      userName: 'u',
      userAvatar: '',
      online: 1,
      status: true,
      data: 'fresh-signature',
      url: '',
      isRecord: false,
    );
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites(
          {required LiveRoomDetail detail}) async =>
      [LivePlayQuality(quality: '高清', data: 'x')];

  @override
  Future<LivePlayUrl> getPlayUrls(
      {required LiveRoomDetail detail,
      required LivePlayQuality quality}) async {
    fetchCount++;
    if (pendingPlayUrl case final pending?) {
      return pending.future;
    }
    if (!urlsAvailable) return LivePlayUrl(urls: []);
    return LivePlayUrl(
        urls: ['http://a/1.flv?expire=300', 'http://a/2.flv?expire=300']);
  }
}

/// 跳过真实播放器与页面副作用
class TestController extends LiveRoomController {
  TestController({required super.pSite, required super.pRoomId});

  int playlistOpens = 0;
  int replayStops = 0;
  int playerJumps = 0;
  Completer<void>? pendingJump;

  @override
  Duration get stablePlaybackDuration => const Duration(milliseconds: 20);

  /// 退避在测试里不引入真实等待；退避数值本身由专门用例断言。
  @override
  Duration get recoveryBaseDelay => Duration.zero;

  @override
  Duration get recoveryMaxDelay => Duration.zero;

  /// 默认关闭合并窗口，让每个 mediaEnd() 都代表一次独立断流。
  /// 合并行为由 _BurstController 单独覆盖验证。
  @override
  Duration get recoveryBurstWindow => Duration.zero;

  @override
  Future<void> initPlaylist() async {
    playlistOpens++;
  }

  @override
  Future<void> stopPlayerForReplay() async {
    replayStops++;
  }

  @override
  Future<void> setPlayer() async {
    playerJumps++;
    if (pendingJump case final pending?) {
      await pending.future;
    }
  }

  @override
  Future<void> changePlayLine(int index) async {
    currentLineIndex = index;
    mediaErrorRetryCount = 0;
  }

  @override
  void addSysMsg(String msg) {}
}

class _LoadingController extends TestController {
  _LoadingController({required super.pSite, required super.pRoomId});

  int loadingShows = 0;
  int loadingDismisses = 0;

  @override
  void showRoomLoading() => loadingShows++;

  @override
  void dismissRoomLoading() => loadingDismisses++;
}

class _PendingRoomSite extends FakeSite {
  _PendingRoomSite() : super(urlsAvailable: false);

  final roomRequests = <Completer<LiveRoomDetail>>[];

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) {
    detailFetchCount++;
    final request = Completer<LiveRoomDetail>();
    roomRequests.add(request);
    return request.future;
  }
}

TestController build(FakeSite fake) {
  var c = TestController(
      pSite: Site(id: 'douyu', name: 'd', logo: '', liveSite: fake),
      pRoomId: '1');
  c.detail.value = LiveRoomDetail(
      roomId: '1',
      title: 't',
      cover: '',
      userName: 'u',
      userAvatar: '',
      online: 1,
      status: true,
      data: '',
      url: '',
      isRecord: false);
  c.qualites.value = [LivePlayQuality(quality: '高清', data: 'x')];
  c.currentQuality = 0;
  // 模拟正在播放中
  c.liveStatus.value = true;
  c.playUrls.value = ['http://old/1.flv', 'http://old/2.flv'];
  c.currentLineIndex = 1; // 最后一条线路
  // 走到"重试次数已用尽"的兜底分支（真实场景由前面的重试累积而来）
  c.mediaErrorRetryCount = 2;
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // WakelockPlus 在测试环境无平台实现会抛异常并中断 mediaEnd/mediaError
    WakelockPlusPlatformInterface.instance = _NoopWakelock();
    // onWSMessage 读取 AppSettingsController.shieldList，
    // 用跳过 Hive 初始化的子类注册，避免依赖本地存储。
    Get.put<AppSettingsController>(_StubSettings());
  });

  tearDown(Get.reset);

  test('地址失效但平台仍给地址：重新获取成功，不误判未开播', () async {
    var fake = FakeSite(urlsAvailable: true);
    var c = build(fake);

    c.mediaEnd();
    await Future.delayed(const Duration(milliseconds: 400));

    expect(fake.fetchCount, 1, reason: '应重新请求一次播放地址');
    expect(c.playlistOpens, 1, reason: '应重建播放列表');
    expect(c.liveStatus.value, true, reason: '不应置为未开播');
  });

  test('旧房间请求结束时不会关闭新房间的加载提示', () async {
    var fake = _PendingRoomSite();
    var controller = _LoadingController(
      pSite: Site(id: 'douyu', name: 'd', logo: '', liveSite: fake),
      pRoomId: '1',
    );

    controller.loadData();
    controller.loadData();
    expect(controller.loadingShows, 2);
    expect(fake.roomRequests, hasLength(2));

    fake.roomRequests.first.complete(
      LiveRoomDetail(
        roomId: '1',
        title: 'stale',
        cover: '',
        userName: 'u',
        userAvatar: '',
        online: 0,
        status: false,
        url: '',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.loadingDismisses, 0);

    fake.roomRequests.last.completeError(StateError('latest failed'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.loadingDismisses, 1);
  });

  test('播放地址接口失败：有限重试且不误判未开播', () async {
    var fake = FakeSite(urlsAvailable: false);
    var c = build(fake);

    c.mediaEnd();
    await Future.delayed(const Duration(milliseconds: 400));

    expect(fake.fetchCount, 3, reason: '应在上限内重试播放地址接口');
    expect(c.liveStatus.value, true, reason: '取址失败不代表主播未开播');
    expect(c.playlistOpens, 0);
  });

  test('mediaError 路径同样生效', () async {
    var fake = FakeSite(urlsAvailable: true);
    var c = build(fake);

    c.mediaError('stream error');
    await Future.delayed(const Duration(milliseconds: 400));

    expect(fake.fetchCount, 1);
    expect(c.liveStatus.value, true);
  });

  test('短暂 playing 事件不会立即清空重试状态', () async {
    var fake = FakeSite(urlsAvailable: true);
    var c = build(fake);

    c.onPlayingChanged(true);
    expect(c.mediaErrorRetryCount, 2);

    c.onPlayingChanged(false);
    await Future<void>.delayed(c.stablePlaybackDuration * 2);
    expect(c.mediaErrorRetryCount, 2);
  });

  test('连续稳定播放后才重置重试状态', () async {
    var fake = FakeSite(urlsAvailable: true);
    var c = build(fake);

    c.onPlayingChanged(true);
    expect(c.mediaErrorRetryCount, 2);

    await Future<void>.delayed(c.stablePlaybackDuration * 2);
    expect(c.mediaErrorRetryCount, 0);
  });

  test('error 与 completed 同时触发时只运行一个恢复流程', () async {
    var fake = FakeSite(urlsAvailable: true);
    var c = build(fake);
    c.mediaErrorRetryCount = 0;
    c.pendingJump = Completer<void>();

    c.mediaError('same failure');
    c.mediaEnd();
    await Future<void>.delayed(Duration.zero);

    expect(c.playerJumps, 1);
    expect(c.mediaErrorRetryCount, 1);

    c.pendingJump!.complete();
    await Future<void>.delayed(Duration.zero);
  });

  test('连续失效的新地址达到上限后停止自动重开', () async {
    var fake = FakeSite(urlsAvailable: true);
    var c = build(fake);

    for (var i = 0; i < 6; i++) {
      c.mediaEnd();
      await Future<void>.delayed(Duration.zero);
    }

    expect(fake.fetchCount, 3);
    expect(c.playlistOpens, 3);
  });

  test('进入回放只停止一次直播，返回后只恢复一次', () async {
    var fake = FakeSite(urlsAvailable: true);
    var c = build(fake);

    await c.suspendForReplay();
    await c.suspendForReplay();
    expect(c.replayStops, 1);

    await c.resumeAfterReplay();
    await c.resumeAfterReplay();
    expect(fake.fetchCount, 1);
    expect(c.playlistOpens, 1);
  });

  test('进入回放后忽略尚未完成的旧直播地址请求', () async {
    var fake = FakeSite(urlsAvailable: true);
    fake.pendingPlayUrl = Completer<LivePlayUrl>();
    var c = build(fake);

    var request = c.getPlayUrl();
    await Future<void>.delayed(Duration.zero);
    await c.suspendForReplay();
    fake.pendingPlayUrl!.complete(
      LivePlayUrl(urls: ['http://stale/live.flv']),
    );

    expect(await request, isFalse);
    expect(c.playlistOpens, 0);
  });

  test('上滚暂停自动滚动时，聊天列表仍有绝对上限', () {
    var fake = FakeSite(urlsAvailable: true);
    var c = build(fake);
    // 模拟用户上滚过：自动滚动已关闭，原逻辑不再裁剪
    c.disableAutoScroll.value = true;
    c.liveStatus.value = false; // 跳过弹幕渲染副作用

    for (var i = 0; i < 1200; i++) {
      c.onWSMessage(LiveMessage(
        type: LiveMessageType.chat,
        userName: 'u',
        message: 'msg$i',
        color: LiveMessageColor.white,
      ));
    }

    expect(c.messages.length, lessThanOrEqualTo(500), reason: '上滚状态下列表不应无限增长');
  });

  test('同一波断流的重复事件只触发一次恢复', () async {
    // 播放器在一次中断里会连抛 error + completed。第一轮恢复结束、
    // 新地址尚未产生 playing 事件时的空窗期里，迟到的事件若不折叠，
    // 会立刻再触发一轮重新取址 —— 这就是"刷新时重复好几次"。
    var fake = FakeSite(urlsAvailable: true);
    var c = _BurstController(
      pSite: Site(id: 'douyu', name: 'd', logo: '', liveSite: fake),
      pRoomId: '1',
    );
    seed(c);

    // 第一轮恢复（取址 + 重建播放列表）
    c.mediaEnd();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(fake.fetchCount, 1);
    expect(c.playlistOpens, 1);

    // 空窗期内迟到的同波事件
    c.mediaError('stream error');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(fake.fetchCount, 1, reason: '同一波断流不应重复取址');
    expect(c.playlistOpens, 1, reason: '同一波断流不应重复重建播放列表');
  });

  test('退避窗口过后的新断流仍会恢复', () async {
    var fake = FakeSite(urlsAvailable: true);
    var c = _BurstController(
      pSite: Site(id: 'douyu', name: 'd', logo: '', liveSite: fake),
      pRoomId: '1',
    );
    seed(c);

    c.mediaEnd();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(fake.fetchCount, 1);

    // 模拟播放稳定后再次断流：窗口与计数都已重置，必须重新恢复
    c.onPlayingChanged(true);
    await Future<void>.delayed(c.stablePlaybackDuration * 2);
    c.mediaError('new stream error');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // 重置后重试计数归零，新一轮走"重载当前线路"分支
    expect(c.playerJumps, 1, reason: '稳定后的新断流不应被旧窗口吞掉');
  });

  test('退避按指数增长并封顶', () {
    var fake = FakeSite(urlsAvailable: true);
    var c = _RealBackoffController(
      pSite: Site(id: 'douyu', name: 'd', logo: '', liveSite: fake),
      pRoomId: '1',
    );

    // 500ms 基准：0.5s, 1s, 2s, 4s ... 封顶 30s
    expect(c.recoveryDelayFor(1), const Duration(milliseconds: 500));
    expect(c.recoveryDelayFor(2), const Duration(seconds: 1));
    expect(c.recoveryDelayFor(3), const Duration(seconds: 2));
    expect(c.recoveryDelayFor(4), const Duration(seconds: 4));
    expect(c.recoveryDelayFor(20), const Duration(seconds: 30), reason: '必须封顶');
  });

  test('单次断流最多一次原地重载，随后直接换地址', () async {
    // 旧实现是「2 次原地重载 + 逐条换线路 + 3 次换地址」，
    // 每级都会重建画面，用户看到的就是反复停顿。
    var fake = FakeSite(urlsAvailable: true);
    var c = TestController(
      pSite: Site(id: 'douyu', name: 'd', logo: '', liveSite: fake),
      pRoomId: '1',
    );
    seed(c);
    c.mediaErrorRetryCount = 0;

    // 第一次：原地重载
    c.mediaError('stream error');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(c.playerJumps, 1);
    expect(fake.fetchCount, 0);

    // 第二次：不再换线路，直接重新取址
    c.mediaError('stream error');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(fake.fetchCount, 1, reason: '第二次失败应直接重新取址');
  });

  test('斗鱼直播正常结束事件跳过失效旧地址并直接重新取址', () async {
    var fake = FakeSite(urlsAvailable: true);
    var c = TestController(
      pSite: Site(id: 'douyu', name: 'd', logo: '', liveSite: fake),
      pRoomId: '1',
    );
    seed(c);
    c.mediaErrorRetryCount = 0;

    c.mediaEnd();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(c.playerJumps, 0, reason: '斗鱼 EOF 后不应重载带旧签名的地址');
    expect(fake.detailFetchCount, 0, reason: '签名应由 core 本地刷新，无需重复请求房间详情');
    expect(fake.fetchCount, 1);
    expect(c.playlistOpens, 1);
  });
}

/// 置为「正在播放中」并沿用 TestController 的测试默认值。
void seed(LiveRoomController c) {
  c.detail.value = LiveRoomDetail(
      roomId: '1',
      title: 't',
      cover: '',
      userName: 'u',
      userAvatar: '',
      online: 1,
      status: true,
      data: '',
      url: '',
      isRecord: false);
  c.qualites.value = [LivePlayQuality(quality: '高清', data: 'x')];
  c.currentQuality = 0;
  c.liveStatus.value = true;
  c.playUrls.value = ['http://old/1.flv', 'http://old/2.flv'];
  c.currentLineIndex = 1;
  c.mediaErrorRetryCount = 2;
}

/// 保留真实退避参数、但不真正等待的控制器。
class _RealBackoffController extends TestController {
  _RealBackoffController({required super.pSite, required super.pRoomId});

  @override
  Duration get recoveryBaseDelay => const Duration(milliseconds: 500);

  @override
  Duration get recoveryMaxDelay => const Duration(seconds: 30);
}

/// 保留真实合并窗口的控制器：用于验证同一波断流被折叠。
class _BurstController extends TestController {
  _BurstController({required super.pSite, required super.pRoomId});

  @override
  Duration get recoveryBurstWindow => const Duration(seconds: 5);
}

/// 测试用 wakelock 实现
class _NoopWakelock extends WakelockPlusPlatformInterface {
  @override
  bool get isMock => true;
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
}

/// 跳过 Hive 初始化的设置控制器（shieldList 默认为空）。
/// 测试替身故意不调用 super.onInit()（它会读取 Hive 本地存储），
/// 因此本文件关闭 must_call_super。
class _StubSettings extends AppSettingsController {
  @override
  void onInit() {}
}
