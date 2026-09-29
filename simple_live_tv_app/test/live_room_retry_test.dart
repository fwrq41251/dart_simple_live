// 验证 TV 端重试逻辑：播放地址失效 vs 房间确实下播
// 对应修复：重试计数用尽后重新获取播放地址，而不是直接判定未开播。
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// 假站点：urlsAvailable=false 模拟"重新取地址也拿不到"（房间已下播）
class FakeSite extends LiveSite {
  FakeSite({required this.urlsAvailable});
  final bool urlsAvailable;
  int fetchCount = 0;

  @override
  String get id => "douyu";
  @override
  String get name => "fake";

  @override
  Future<List<LivePlayQuality>> getPlayQualites(
          {required LiveRoomDetail detail}) async =>
      [LivePlayQuality(quality: '高清', data: 'x')];

  @override
  Future<LivePlayUrl> getPlayUrls(
      {required LiveRoomDetail detail, required LivePlayQuality quality}) async {
    fetchCount++;
    if (!urlsAvailable) return LivePlayUrl(urls: []);
    return LivePlayUrl(
        urls: ['http://a/1.flv?expire=300', 'http://a/2.flv?expire=300']);
  }
}

/// 跳过真实播放器与页面副作用
class TestController extends LiveRoomController {
  TestController({required super.pSite, required super.pRoomId});

  @override
  void setPlayer() async {}

  @override
  void changePlayLine(int index) {
    currentLineIndex = index;
    mediaErrorRetryCount = 0;
  }

}

TestController build(FakeSite fake) {
  var c = TestController(
      pSite: Site(
          id: 'douyu', name: 'd', logo: '', liveSite: fake, index: 0),
      pRoomId: '1');
  c.detail.value = LiveRoomDetail(
      roomId: '1', title: 't', cover: '', userName: 'u', userAvatar: '',
      online: 1, status: true, data: '', url: '', isRecord: false);
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
  });

  test('地址失效但平台仍给地址：重新获取成功，不误判未开播', () async {
    var fake = FakeSite(urlsAvailable: true);
    var c = build(fake);

    c.mediaEnd();
    await Future.delayed(const Duration(milliseconds: 400));

    expect(fake.fetchCount, 1, reason: '应重新请求一次播放地址');
    expect(c.liveStatus.value, true, reason: '不应置为未开播');
  });

  test('房间确实下播：重新获取拿不到地址，判定未开播', () async {
    var fake = FakeSite(urlsAvailable: false);
    var c = build(fake);

    c.mediaEnd();
    await Future.delayed(const Duration(milliseconds: 400));

    expect(fake.fetchCount, 1, reason: '应重新请求一次播放地址');
    expect(c.liveStatus.value, false, reason: '应判定为未开播');
  });

  test('mediaError 路径同样生效', () async {
    var fake = FakeSite(urlsAvailable: true);
    var c = build(fake);

    c.mediaError('stream error');
    await Future.delayed(const Duration(milliseconds: 400));

    expect(fake.fetchCount, 1);
    expect(c.liveStatus.value, true);
  });

  test('播放恢复时重置重试计数', () async {
    var fake = FakeSite(urlsAvailable: true);
    var c = build(fake);

    c.onPlayingChanged(true);

    expect(c.mediaErrorRetryCount, 0);
  });
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
