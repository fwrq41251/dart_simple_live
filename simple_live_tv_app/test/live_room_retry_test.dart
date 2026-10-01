// 验证 TV 端重试逻辑：播放地址失效 vs 房间确实下播
// 对应修复：重试计数用尽后重新获取播放地址，而不是直接判定未开播。
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_tv_app/services/diagnostic_service.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// 假站点：urlsAvailable=false 模拟播放地址接口暂时不可用。
class FakeSite extends LiveSite {
  FakeSite({required this.urlsAvailable, this.fetchDelay = Duration.zero});
  final bool urlsAvailable;
  final Duration fetchDelay;
  int fetchCount = 0;

  @override
  String get id => "douyu";
  @override
  String get name => "fake";

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async =>
      [LivePlayQuality(quality: '高清', data: 'x')];

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    fetchCount++;
    await Future<void>.delayed(fetchDelay);
    if (!urlsAvailable) return LivePlayUrl(urls: []);
    return LivePlayUrl(
      urls: ['http://a/1.flv?expire=300', 'http://a/2.flv?expire=300'],
    );
  }
}

/// 跳过真实播放器与页面副作用
class TestController extends LiveRoomController {
  TestController({required super.pSite, required super.pRoomId});

  int playerOpens = 0;

  @override
  Duration get stablePlaybackDuration => const Duration(milliseconds: 20);

  @override
  Duration get recoveryBaseDelay => Duration.zero;

  @override
  Duration get recoveryMaxDelay => Duration.zero;

  @override
  Duration get recoveryBurstWindow => Duration.zero;

  @override
  Future<void> setPlayer() async {
    playerOpens++;
  }

  @override
  Future<void> changePlayLine(int index) async {
    currentLineIndex = index;
    mediaErrorRetryCount = 0;
  }
}

TestController build(FakeSite fake) {
  var c = TestController(
    pSite: Site(id: 'douyu', name: 'd', logo: '', liveSite: fake, index: 0),
    pRoomId: '1',
  );
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
    isRecord: false,
  );
  c.qualites.value = [LivePlayQuality(quality: '高清', data: 'x')];
  c.currentQuality = 0;
  c.liveStatus.value = true;
  c.playUrls.value = ['http://old/1.flv', 'http://old/2.flv'];
  c.currentLineIndex = 1; // 最后一条线路
  c.mediaErrorRetryCount = 2; // 重试次数已用尽
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // WakelockPlus 在测试环境无平台实现会抛异常并中断 mediaEnd/mediaError
    WakelockPlusPlatformInterface.instance = _NoopWakelock();
    if (!Get.isRegistered<DiagnosticService>()) {
      Get.put(DiagnosticService());
    }
  });

  test('地址失效但平台仍给地址：重新获取成功，不误判未开播', () async {
    var fake = FakeSite(urlsAvailable: true);
    var c = build(fake);

    c.mediaEnd();
    await Future.delayed(const Duration(milliseconds: 400));

    expect(fake.fetchCount, 1, reason: '应重新请求一次播放地址');
    expect(c.liveStatus.value, true, reason: '不应置为未开播');
  });

  test('取址失败：有限重试，不误判未开播并给出手动入口', () async {
    var fake = FakeSite(urlsAvailable: false);
    var c = build(fake);

    c.mediaEnd();
    await Future.delayed(const Duration(milliseconds: 400));

    expect(fake.fetchCount, 3, reason: '应在上限内重试');
    expect(c.liveStatus.value, true, reason: '只有房间详情能明确判定下播');
    expect(c.canManuallyRetry, true);
    expect(c.recoveryStatus.value, contains('自动恢复停止'));
  });

  test('mediaError 路径同样生效', () async {
    var fake = FakeSite(urlsAvailable: true);
    var c = build(fake);

    c.mediaError('stream error');
    await Future.delayed(const Duration(milliseconds: 400));

    expect(fake.fetchCount, 1);
    expect(c.liveStatus.value, true);
  });

  test('短暂 playing 不重置，稳定播放后才重置恢复状态', () async {
    var fake = FakeSite(urlsAvailable: true);
    var c = build(fake);

    c.onPlayingChanged(true);
    expect(c.mediaErrorRetryCount, 2);
    await Future<void>.delayed(c.stablePlaybackDuration * 2);
    expect(c.mediaErrorRetryCount, 0);
    expect(c.recoveryStatus.value, isEmpty);
  });

  test('同一波 error/completed 只执行一个恢复流程', () async {
    var fake = FakeSite(urlsAvailable: true);
    var c = _BurstController(
      pSite: Site(
        id: 'bilibili',
        name: 'b',
        logo: '',
        liveSite: fake,
        index: 0,
      ),
      pRoomId: '1',
    );
    seed(c);
    c.mediaErrorRetryCount = 0;

    c.mediaError('same failure');
    c.mediaEnd();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(c.playerOpens, 1);
    expect(fake.fetchCount, 0);
  });

  test('单次原地址重开后，下一次断流重新取址', () async {
    var fake = FakeSite(urlsAvailable: true);
    var c = build(fake);
    c.mediaErrorRetryCount = 0;

    c.mediaError('first');
    await Future<void>.delayed(Duration.zero);
    expect(c.playerOpens, 1);
    expect(c.recoveryStatus.value, '正在重连');

    c.mediaError('second');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(fake.fetchCount, 1);
    expect(c.recoveryStatus.value, contains('切换线路'));
  });

  test('斗鱼 completed 跳过旧签名地址并直接重新取址', () async {
    var fake = FakeSite(urlsAvailable: true);
    var c = build(fake);
    c.mediaErrorRetryCount = 0;

    c.mediaEnd();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(c.playerOpens, 1, reason: '仅打开新取回的地址');
    expect(fake.fetchCount, 1);
  });

  test('指数退避增长并封顶 30 秒', () {
    var fake = FakeSite(urlsAvailable: true);
    var c = _BackoffController(
      pSite: Site(id: 'douyu', name: 'd', logo: '', liveSite: fake, index: 0),
      pRoomId: '1',
    );

    expect(c.recoveryDelayFor(1), const Duration(milliseconds: 500));
    expect(c.recoveryDelayFor(2), const Duration(seconds: 1));
    expect(c.recoveryDelayFor(4), const Duration(seconds: 4));
    expect(c.recoveryDelayFor(20), const Duration(seconds: 30));
  });

  test('手动刷新后忽略仍在等待的旧恢复任务', () async {
    var fake = FakeSite(
      urlsAvailable: false,
      fetchDelay: const Duration(milliseconds: 20),
    );
    var c = build(fake);

    c.mediaEnd();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    var manualRequest = c.getPlayUrl(resetRecovery: true);
    await manualRequest;
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(fake.fetchCount, 2, reason: '旧恢复任务不能在重置后继续递归重试');
    expect(c.canManuallyRetry, false);
  });
}

void seed(TestController c) {
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
    isRecord: false,
  );
  c.qualites.value = [LivePlayQuality(quality: '高清', data: 'x')];
  c.currentQuality = 0;
  c.liveStatus.value = true;
  c.playUrls.value = ['http://old/1.flv'];
  c.currentLineIndex = 0;
}

class _BurstController extends TestController {
  _BurstController({required super.pSite, required super.pRoomId});

  @override
  Duration get recoveryBurstWindow => const Duration(seconds: 5);
}

class _BackoffController extends TestController {
  _BackoffController({required super.pSite, required super.pRoomId});

  @override
  Duration get recoveryBaseDelay => const Duration(milliseconds: 500);

  @override
  Duration get recoveryMaxDelay => const Duration(seconds: 30);
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
