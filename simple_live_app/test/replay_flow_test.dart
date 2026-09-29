// ignore_for_file: must_call_super
// 回放 app 层验证：ReplayListController 与 LiveSite 的接线。
// 真实网络链路由 simple_live_core/test 的回放集成测试覆盖
// （flutter test 环境会用 HttpOverrides 拦截所有请求，不适合打真实网络）。
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/replay/replay_list_controller.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 跳过 Hive 初始化的设置控制器
class _StubSettings extends AppSettingsController {
  @override
  void onInit() {}
}

/// 假站点：可控地返回回放数据
class _FakeReplaySite extends LiveSite {
  _FakeReplaySite({required this.support, required this.sessions});
  final bool support;
  final List<LiveReplaySession> sessions;
  int callCount = 0;
  int? lastPage;

  @override
  String get id => 'douyu';
  @override
  String get name => 'fake';

  @override
  bool get supportReplay => support;

  @override
  Future<LiveReplayListResult> getReplayList({
    required String roomId,
    int page = 1,
  }) async {
    callCount++;
    lastPage = page;
    return LiveReplayListResult(count: 42, items: sessions);
  }
}

LiveReplaySession _session(String hashId) => LiveReplaySession(
      showId: 1,
      title: '标题',
      time: '2026-09-28 12点场',
      dateFormat: '昨天',
      timeFormat: '12:00',
      items: [
        LiveReplayItem(
          hashId: hashId,
          title: '分段',
          cover: '',
          duration: 100,
          strDuration: '00:01:40',
          startTime: 0,
          viewNum: 1,
          pointId: 1,
        ),
      ],
    );

ReplayListController _controller(_FakeReplaySite site) => ReplayListController(
      pSite: Site(id: 'douyu', name: '斗鱼', logo: '', liveSite: site),
      pRoomId: '9999',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Get.put<AppSettingsController>(_StubSettings());
  });
  tearDown(Get.reset);

  test('加载回放列表并回填场次数', () async {
    final site = _FakeReplaySite(
      support: true,
      sessions: [_session('abc123'), _session('def456')],
    );
    final c = _controller(site);

    expect(c.supportReplay, isTrue);

    final items = await c.getData(1, 20);

    expect(site.callCount, 1);
    expect(site.lastPage, 1);
    expect(items.length, 2);
    expect(items.first.items.first.hashId, 'abc123');
    // 场次数应回填到可观察状态
    expect(c.replayCount.value, 42);
  });

  test('不支持的平台直接返回空，且不发起请求', () async {
    final site = _FakeReplaySite(support: false, sessions: [_session('x')]);
    final c = _controller(site);

    expect(c.supportReplay, isFalse);
    final items = await c.getData(1, 20);

    expect(items, isEmpty);
    expect(site.callCount, 0, reason: '不支持时不应请求接口');
  });

  test('平台返回空列表时不报错', () async {
    final site = _FakeReplaySite(support: true, sessions: []);
    final c = _controller(site);

    final items = await c.getData(1, 20);

    expect(items, isEmpty);
    expect(site.callCount, 1);
  });

  test('翻页时把页码透传给平台', () async {
    final site = _FakeReplaySite(support: true, sessions: [_session('p2')]);
    final c = _controller(site);

    await c.getData(2, 20);

    expect(site.lastPage, 2);
  });
}
