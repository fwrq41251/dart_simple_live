// ignore_for_file: must_call_super
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/replay/replay_controller.dart';
import 'package:simple_live_app/modules/replay/replay_page.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _ReplaySite extends LiveSite {
  @override
  String get id => 'douyu';

  @override
  String get name => '斗鱼';
}

class _TestReplayController extends ReplayController {
  _TestReplayController()
      : super(
          pSite: Site(
            id: 'douyu',
            name: '斗鱼',
            logo: '',
            liveSite: _ReplaySite(),
          ),
          pRoomId: '9999',
          pItem: LiveReplayItem(
            hashId: 'test',
            title: '桌面回放测试',
            cover: '',
            duration: 3600,
            strDuration: '01:00:00',
            startTime: 0,
            viewNum: 123,
            pointId: 1,
          ),
        );

  int prepareCount = 0;

  @override
  void onInit() {}

  @override
  Future<void> prepareForExit() async {
    prepareCount++;
  }

  @override
  void onClose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Get.put<ReplayController>(_TestReplayController());
  });

  tearDown(Get.reset);

  testWidgets('宽屏使用播放器加信息侧栏且无布局溢出', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const GetMaterialApp(
        home: ReplayPage.withPlayer(
          player: ColoredBox(
            key: Key('player'),
            color: Colors.black,
          ),
        ),
      ),
    );

    expect(find.text('桌面回放测试'), findsNWidgets(2));
    var player = tester.getRect(find.byKey(const Key('player')));
    var info = tester.getRect(find.text('123 次观看'));
    expect(info.left, greaterThanOrEqualTo(player.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口使用上下布局且不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const GetMaterialApp(
        home: ReplayPage.withPlayer(
          player: ColoredBox(
            key: Key('player'),
            color: Colors.black,
          ),
        ),
      ),
    );

    var player = tester.getRect(find.byKey(const Key('player')));
    var info = tester.getRect(find.text('123 次观看'));
    expect(info.top, greaterThanOrEqualTo(player.bottom));
    expect(tester.takeException(), isNull);
  });

  test('退出前先停止播放器并开放路由返回', () async {
    var controller = Get.find<ReplayController>() as _TestReplayController;

    expect(controller.allowPop.value, isFalse);
    expect(await controller.requestExit(), isTrue);
    expect(controller.allowPop.value, isTrue);
    expect(controller.prepareCount, 1);
    expect(await controller.requestExit(), isFalse);
  });

  testWidgets('读取结束后转圈消失', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var controller = Get.find<ReplayController>();
    controller.loading.value = true;

    await tester.pumpWidget(
      const GetMaterialApp(
        home: ReplayPage.withPlayer(
          player: ColoredBox(key: Key('player'), color: Colors.black),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // 播放地址读取完成后 loading 归位，浮层必须跟着消失。
    // 之前该浮层读的是 Obx 之外的 loading，依赖未注册，转圈会一直留在画面上。
    controller.loading.value = false;
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('读取失败时展示重试入口', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var controller = Get.find<ReplayController>();
    controller.loading.value = false;
    controller.loadError.value = true;

    await tester.pumpWidget(
      const GetMaterialApp(
        home: ReplayPage.withPlayer(
          player: ColoredBox(key: Key('player'), color: Colors.black),
        ),
      ),
    );

    expect(find.text('无法读取回放'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('总时长读取后信息栏更新', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var controller = Get.find<ReplayController>();

    await tester.pumpWidget(
      const GetMaterialApp(
        home: ReplayPage.withPlayer(
          player: ColoredBox(key: Key('player'), color: Colors.black),
        ),
      ),
    );

    // 信息栏最初读到的是零时长，播放器上报后必须重建为真实时长。
    controller.duration.value = const Duration(hours: 2, minutes: 2);
    await tester.pump();

    expect(find.textContaining('02:02:00'), findsOneWidget);
  });
}
