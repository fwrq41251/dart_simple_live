// ignore_for_file: must_call_super
import 'dart:async';
import 'dart:ui' as ui;

import 'package:extended_image/extended_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/replay/replay_controller.dart';
import 'package:simple_live_app/modules/replay/replay_page.dart';
import 'package:simple_live_app/modules/replay/replay_progress_bar.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _ReplaySite extends LiveSite
    implements LiveReplayDanmakuSite, LiveReplayPreviewSite {
  int replayUrlCalls = 0;
  Completer<LiveReplayUrl>? pendingReplayUrl;
  bool failPreview = false;

  @override
  Future<LiveReplayPreview> getReplayPreview({required String hashId}) async {
    if (failPreview) throw Exception('preview unavailable');
    return LiveReplayPreview(urls: ['https://preview.test/sheet.jpg']);
  }

  @override
  String get id => 'douyu';

  @override
  String get name => '斗鱼';

  @override
  Future<LiveReplayUrl> getReplayUrl({
    required String roomId,
    required String hashId,
  }) async {
    replayUrlCalls++;
    if (pendingReplayUrl case final pending?) {
      return pending.future;
    }
    return LiveReplayUrl(
      qualities: [
        LiveReplayQuality(quality: 'high', name: '高清', url: 'high'),
      ],
    );
  }

  @override
  Future<LiveReplayDanmakuResult> getReplayDanmaku({
    required String hashId,
    required int startTime,
  }) async {
    return LiveReplayDanmakuResult(
      startTime: startTime,
      endTime: -1,
      items: [
        LiveReplayDanmaku(time: 1000, text: 'first', color: 0xFFFFFFFF),
        LiveReplayDanmaku(time: 1600, text: 'second', color: 0xFFFF5654),
        LiveReplayDanmaku(time: 5000, text: 'after seek', color: 0xFFFFFFFF),
      ],
    );
  }
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
  final emittedDanmaku = <LiveReplayDanmaku>[];
  Duration? openedAt;
  bool? openedPlaying;
  int? savedProgress;
  final writtenProgress = <int>[];
  var removedProgressCount = 0;
  var openCount = 0;

  _ReplaySite get replaySite => site.liveSite as _ReplaySite;

  @override
  void onInit() {}

  @override
  Future<void> prepareForExit() async {
    prepareCount++;
  }

  @override
  void emitReplayDanmaku(LiveReplayDanmaku item) {
    emittedDanmaku.add(item);
  }

  @override
  Future<void> playCurrent({Duration? start, bool play = true}) async {
    openCount++;
    openedAt = start;
    openedPlaying = play;
  }

  @override
  int? readReplayProgress() => savedProgress;

  @override
  Future<void> writeReplayProgress(int milliseconds) async {
    writtenProgress.add(milliseconds);
  }

  @override
  Future<void> removeReplayProgress() async {
    removedProgressCount++;
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

  test('预览接口失败不影响回放播放', () async {
    final controller = Get.find<ReplayController>() as _TestReplayController;
    controller.replaySite.failPreview = true;
    await Future.wait([controller.loadReplayPreview(), controller.loadData()]);
    expect(controller.preview.value, isNull);
    expect(controller.openCount, 1);
    expect(controller.loadError.value, isFalse);
  });

  testWidgets('预览按目标时间裁剪正确的单格，而不是相邻格或整张拼图', (tester) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
        const Rect.fromLTWH(0, 0, 160, 100), Paint()..color = Colors.blue);
    // 20:35 位于第二张图的第3行、第4列；行列互换会得到蓝色。
    canvas.drawRect(
        const Rect.fromLTWH(48, 20, 16, 10), Paint()..color = Colors.red);
    final picture = recorder.endRecording();
    late ui.Image sheet;
    await tester.runAsync(() async => sheet = await picture.toImage(160, 100));
    picture.dispose();
    const url = 'https://preview.test/crop.jpg';
    PaintingBinding.instance.imageCache.putIfAbsent(
      ExtendedNetworkImageProvider(url, cache: true),
      () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: sheet))),
    );
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      home: RepaintBoundary(
        key: key,
        child: Scaffold(
            body: Center(
                child: SizedBox(
          width: 400,
          child: ReplayProgressBar(
            position: Duration.zero,
            duration: const Duration(seconds: 2000),
            preview: LiveReplayPreview(urls: ['', url]),
            onSeek: (_) {},
            onInteraction: (_) {},
          ),
        ))),
      ),
    ));
    final rect = tester.getRect(find.byType(Slider));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: rect.center);
    await mouse.moveTo(
        Offset(rect.left + 16 + (rect.width - 32) * .6175, rect.center.dy));
    await tester.pumpAndSettle();
    final label = tester.getRect(find.text('20:35'));
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final rendered = await boundary.toImage();
      final pixels = (await rendered.toByteData())!.buffer.asUint8List();
      final point =
          boundary.globalToLocal(Offset(label.center.dx, label.top - 30));
      final offset = (point.dy.floor() * rendered.width + point.dx.floor()) * 4;
      expect(pixels.sublist(offset, offset + 4), [244, 67, 54, 255]);
      rendered.dispose();
    });
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    PaintingBinding.instance.imageCache.clear();
  });

  testWidgets('进度条悬停不 seek，拖动只在松手后跳转，无预览仍显示时间', (tester) async {
    final seeks = <Duration>[];
    final controller = Get.find<ReplayController>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            child: ReplayProgressBar(
              position: const Duration(seconds: 100),
              duration: const Duration(seconds: 1000),
              onSeek: seeks.add,
              onInteraction: controller.setProgressInteraction,
            ),
          ),
        ),
      ),
    ));
    final rect = tester.getRect(find.byType(Slider));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset(rect.left, rect.center.dy));
    await mouse.moveTo(rect.center);
    await tester.pump();
    expect(find.text('08:20'), findsOneWidget);
    expect(seeks, isEmpty);
    await tester.pump(const Duration(seconds: 5));
    expect(controller.showControls.value, isTrue);
    await mouse.removePointer();
    await tester.pump();
    expect(find.text('08:20'), findsNothing);

    final touch = await tester.startGesture(
      Offset(rect.left + 16 + (rect.width - 32) * 0.1, rect.center.dy),
    );
    await touch.moveTo(
      Offset(rect.left + 16 + (rect.width - 32) * 0.75, rect.center.dy),
    );
    await tester.pump();
    expect(seeks, isEmpty);
    expect(find.text('12:30'), findsOneWidget);
    await touch.up();
    await tester.pump();
    expect(seeks, [const Duration(seconds: 750)]);
    expect(find.text('12:30'), findsNothing);
    await tester.pump(const Duration(seconds: 4));
    expect(controller.showControls.value, isFalse);

    // 布局切换移除正在悬停的进度条后，控制栏恢复自动隐藏。
    final anotherMouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await anotherMouse.addPointer(location: rect.center);
    await anotherMouse.moveTo(rect.center + const Offset(1, 0));
    await tester.pump();
    expect(controller.showControls.value, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
    expect(controller.showControls.value, isFalse);
    await anotherMouse.removePointer();
    expect(tester.takeException(), isNull);
  });

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

  test('回放弹幕按时间只投递一次，seek 后从新位置继续', () async {
    var controller = Get.find<ReplayController>() as _TestReplayController;
    controller.showDanmaku.value = true;
    await controller.loadReplayDanmakuAt(0);

    controller.onReplayPositionChanged(const Duration(milliseconds: 900));
    controller.onReplayPositionChanged(const Duration(milliseconds: 1100));
    controller.onReplayPositionChanged(const Duration(milliseconds: 1700));
    controller.onReplayPositionChanged(const Duration(milliseconds: 1700));

    expect(controller.emittedDanmaku.map((e) => e.text), ['first', 'second']);

    await controller.synchronizeDanmakuAfterSeek(
      const Duration(milliseconds: 4500),
    );
    controller.onReplayPositionChanged(const Duration(milliseconds: 5100));

    expect(
      controller.emittedDanmaku.map((e) => e.text),
      ['first', 'second', 'after seek'],
    );
  });

  test('切换清晰度时从当前进度打开并保留暂停状态', () async {
    var controller = Get.find<ReplayController>() as _TestReplayController;
    controller.qualities.value = [
      LiveReplayQuality(quality: 'high', name: '高清', url: 'high'),
      LiveReplayQuality(quality: 'super', name: '超清', url: 'super'),
    ];
    controller.currentQuality.value = 0;
    controller.position.value = const Duration(minutes: 23, seconds: 45);
    controller.playing.value = false;

    await controller.changeQuality(1);

    expect(controller.currentQuality.value, 1);
    expect(controller.openedAt, const Duration(minutes: 23, seconds: 45));
    expect(controller.openedPlaying, isFalse);
    expect(controller.position.value, const Duration(minutes: 23, seconds: 45));
  });

  test('重新进入回放时从保存进度开始播放', () async {
    var controller = Get.find<ReplayController>() as _TestReplayController;
    controller.savedProgress =
        const Duration(minutes: 18, seconds: 21).inMilliseconds;

    await controller.loadData();

    expect(controller.openedAt, const Duration(minutes: 18, seconds: 21));
    expect(controller.position.value, const Duration(minutes: 18, seconds: 21));
  });

  test('并发重试共用同一次回放地址加载和播放器打开', () async {
    var controller = Get.find<ReplayController>() as _TestReplayController;
    controller.replaySite.pendingReplayUrl = Completer<LiveReplayUrl>();

    var first = controller.loadData();
    var second = controller.loadData();
    expect(identical(first, second), isTrue);
    expect(controller.replaySite.replayUrlCalls, 1);

    controller.replaySite.pendingReplayUrl!.complete(
      LiveReplayUrl(
        qualities: [
          LiveReplayQuality(quality: 'high', name: '高清', url: 'high'),
        ],
      ),
    );
    await Future.wait([first, second]);

    expect(controller.openCount, 1);
    expect(controller.loading.value, isFalse);
  });

  test('短进度不保存，正常进度保存，接近结尾时清除', () async {
    var controller = Get.find<ReplayController>() as _TestReplayController;

    controller.position.value = const Duration(seconds: 9);
    await controller.saveReplayProgress(force: true);
    expect(controller.writtenProgress, isEmpty);

    controller.position.value = const Duration(minutes: 20);
    await controller.saveReplayProgress(force: true);
    expect(controller.writtenProgress,
        [const Duration(minutes: 20).inMilliseconds]);

    controller.position.value = const Duration(minutes: 59, seconds: 40);
    await controller.saveReplayProgress(force: true);
    expect(controller.removedProgressCount, 1);
  });

  test('已看完或保存位置接近结尾时下次从头播放', () async {
    var controller = Get.find<ReplayController>() as _TestReplayController;
    controller.savedProgress =
        const Duration(minutes: 59, seconds: 40).inMilliseconds;

    await controller.loadData();

    expect(controller.openedAt, isNull);
    expect(controller.position.value, Duration.zero);
    expect(controller.removedProgressCount, 1);

    controller.onReplayCompleted();
    await controller.saveReplayProgress(force: true);
    expect(controller.removedProgressCount, 2);
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
