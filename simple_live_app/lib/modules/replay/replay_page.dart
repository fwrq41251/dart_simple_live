import 'dart:io';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/replay/replay_controller.dart';
import 'package:simple_live_app/widgets/desktop_player_shortcuts.dart';

/// 回放播放页
class ReplayPage extends GetView<ReplayController> {
  final Widget? _playerOverride;

  const ReplayPage({Key? key})
      : _playerOverride = null,
        super(key: key);

  @visibleForTesting
  const ReplayPage.withPlayer({
    required Widget player,
    Key? key,
  })  : _playerOverride = player,
        super(key: key);

  @override
  Widget build(BuildContext context) {
    var page = Obx(() {
      var fullScreen = controller.fullScreen.value;
      return PopScope(
        canPop: controller.allowPop.value,
        onPopInvokedWithResult: (didPop, result) async {
          if (didPop) {
            return;
          }
          if (controller.fullScreen.value) {
            await controller.toggleFullScreen();
            return;
          }
          if (await controller.requestExit()) {
            await WidgetsBinding.instance.endOfFrame;
            if (context.mounted) {
              Navigator.of(context).pop(result);
            }
          }
        },
        child: Scaffold(
          backgroundColor: fullScreen
              ? Colors.black
              : Theme.of(context).scaffoldBackgroundColor,
          appBar: fullScreen
              ? null
              : AppBar(
                  title: Text(
                    controller.pItem.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
          body: fullScreen ? _buildPlayer(context) : _buildPageBody(context),
        ),
      );
    });
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return page;
    }
    return DesktopPlayerShortcuts(
      onTogglePlay: controller.togglePlay,
      onToggleFullScreen: controller.toggleFullScreen,
      onToggleMute: controller.toggleMute,
      onVolumeUp: () => controller.adjustVolume(5),
      onVolumeDown: () => controller.adjustVolume(-5),
      onSeekBackward: () => controller.seekTo(
        controller.position.value - const Duration(seconds: 10),
      ),
      onSeekForward: () => controller.seekTo(
        controller.position.value + const Duration(seconds: 10),
      ),
      onEscape: () => Navigator.of(context).maybePop(),
      child: page,
    );
  }

  Widget _buildPageBody(BuildContext context) {
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          var useWideLayout = constraints.maxWidth >= 900;
          if (useWideLayout) {
            return Row(
              children: [
                Expanded(
                  child: ColoredBox(
                    color: Colors.black,
                    child: _buildPlayer(context),
                  ),
                ),
                SizedBox(
                  width: 340,
                  child: _buildInfo(context),
                ),
              ],
            );
          }
          return Column(
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: _buildPlayer(context),
              ),
              Expanded(child: _buildInfo(context)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPlayer(BuildContext context) {
    return MouseRegion(
      onHover: (_) => controller.showControlsTemporarily(),
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          children: [
            // 测试用替身只替换视频画面本身，加载浮层保持真实，
            // 否则覆盖件会绕过浮层，测试也就覆盖不到它。
            if (_playerOverride case final player?)
              player
            else
              Video(
                key: controller.globalPlayerKey,
                controller: controller.videoController,
                fit: BoxFit.contain,
                controls: (state) => _buildControls(state),
              ),
            // 浮层必须在 Obx 内：_buildPlayer 处于 build() 的 Obx 之外，
            // 直接读 loading 不会注册依赖，播放开始后转圈会一直留在画面上。
            Obx(() {
              if (controller.loading.value) {
                return const Center(
                  child: CircularProgressIndicator(),
                );
              }
              if (controller.loadError.value) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Remix.error_warning_line,
                        color: Colors.white,
                        size: 48,
                      ),
                      AppStyle.vGap12,
                      const Text(
                        "无法读取回放",
                        style: TextStyle(color: Colors.white),
                      ),
                      AppStyle.vGap12,
                      TextButton(
                        onPressed: controller.loadData,
                        child: const Text("重试"),
                      ),
                    ],
                  ),
                );
              }
              return const SizedBox.shrink();
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(VideoState state) {
    return Obx(
      () => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: controller.showControlsTemporarily,
        onDoubleTap: controller.toggleFullScreen,
        child: Container(
          color: Colors.transparent,
          child: Stack(
            children: [
              if (controller.supportsReplayDanmaku) _buildDanmakuView(),
              Column(
                children: [
                  if (controller.showControls.value &&
                      controller.fullScreen.value)
                    Row(
                      children: [
                        IconButton(
                          tooltip: "退出全屏",
                          onPressed: controller.toggleFullScreen,
                          icon: const Icon(
                            Icons.arrow_back,
                            color: Colors.white,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            controller.pItem.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  const Expanded(child: SizedBox()),
                  if (controller.showControls.value) _buildBottomBar(),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDanmakuView() {
    controller.danmakuView ??= DanmakuScreen(
      key: controller.globalDanmakuKey,
      createdController: controller.initDanmakuController,
      option: controller.danmakuOption,
    );
    return Positioned.fill(
      child: IgnorePointer(
        child: Offstage(
          offstage: !controller.showDanmaku.value,
          child: Padding(
            padding: EdgeInsets.only(
              top: AppSettingsController.instance.danmuTopMargin.value,
              bottom: AppSettingsController.instance.danmuBottomMargin.value,
            ),
            child: controller.danmakuView!,
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      color: Colors.black54,
      padding: AppStyle.edgeInsetsA8,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Obx(
                () => Text(
                  "${Utils.formatDuration(controller.position.value)} / "
                  "${Utils.formatDuration(controller.duration.value)}",
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
              Expanded(
                child: Obx(
                  () => Slider(
                    value: _sliderValue(),
                    onChanged: (v) {
                      controller.seekTo(
                        Duration(
                          milliseconds:
                              (controller.duration.value.inMilliseconds * v)
                                  .round(),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            children: [
              IconButton(
                tooltip: "后退 15 秒",
                onPressed: () => controller.seekTo(
                  controller.position.value - const Duration(seconds: 15),
                ),
                icon: const Icon(Remix.replay_15_line, color: Colors.white),
              ),
              Obx(
                () => IconButton(
                  tooltip: controller.playing.value ? "暂停" : "播放",
                  onPressed: controller.togglePlay,
                  icon: Icon(
                    controller.playing.value
                        ? Remix.pause_fill
                        : Remix.play_fill,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
              ),
              IconButton(
                tooltip: "前进 15 秒",
                onPressed: () => controller.seekTo(
                  controller.position.value + const Duration(seconds: 15),
                ),
                icon: const Icon(Remix.forward_15_line, color: Colors.white),
              ),
              _buildSpeedButton(),
              _buildQualityButton(),
              if (controller.supportsReplayDanmaku)
                IconButton(
                  onPressed: controller.toggleDanmaku,
                  tooltip: controller.showDanmaku.value ? "关闭弹幕" : "打开弹幕",
                  icon: ImageIcon(
                    AssetImage(
                      controller.showDanmaku.value
                          ? 'assets/icons/icon_danmaku_close.png'
                          : 'assets/icons/icon_danmaku_open.png',
                    ),
                    size: 24,
                    color: Colors.white,
                  ),
                ),
              Obx(
                () => IconButton(
                  tooltip: controller.fullScreen.value ? "退出全屏" : "进入全屏",
                  onPressed: controller.toggleFullScreen,
                  icon: Icon(
                    controller.fullScreen.value
                        ? Remix.fullscreen_exit_line
                        : Remix.fullscreen_line,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  double _sliderValue() {
    var total = controller.duration.value.inMilliseconds;
    if (total <= 0) {
      return 0;
    }
    var current = controller.position.value.inMilliseconds;
    return (current / total).clamp(0.0, 1.0);
  }

  Widget _buildSpeedButton() {
    return Obx(
      () => PopupMenuButton<double>(
        initialValue: controller.speed.value,
        onSelected: controller.setSpeed,
        itemBuilder: (_) => const [
          PopupMenuItem(value: 0.5, child: Text("0.5x")),
          PopupMenuItem(value: 0.75, child: Text("0.75x")),
          PopupMenuItem(value: 1.0, child: Text("1.0x")),
          PopupMenuItem(value: 1.25, child: Text("1.25x")),
          PopupMenuItem(value: 1.5, child: Text("1.5x")),
          PopupMenuItem(value: 2.0, child: Text("2.0x")),
        ],
        child: Padding(
          padding: AppStyle.edgeInsetsA4,
          child: Text(
            "${controller.speed.value}x",
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ),
    );
  }

  Widget _buildQualityButton() {
    return Obx(
      () => PopupMenuButton<int>(
        initialValue: controller.currentQuality.value,
        onSelected: controller.changeQuality,
        itemBuilder: (_) => controller.qualities
            .asMap()
            .entries
            .map(
              (e) => PopupMenuItem(
                value: e.key,
                child: Text(e.value.name),
              ),
            )
            .toList(),
        child: const Padding(
          padding: AppStyle.edgeInsetsA4,
          child: Icon(Remix.hd_line, color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildInfo(BuildContext context) {
    // duration 在读取到总时长后才更新，必须在 Obx 内读取才会重建。
    return Obx(
      () => Container(
        width: double.infinity,
        color: Theme.of(context).scaffoldBackgroundColor,
        padding: AppStyle.edgeInsetsA16,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                controller.pItem.title,
                style: Get.textTheme.titleMedium,
              ),
              AppStyle.vGap8,
              Text(
                "${controller.site.name}  ·  "
                "${Utils.formatDuration(controller.duration.value)}",
                style: Get.textTheme.bodySmall,
              ),
              if (controller.pItem.viewNum > 0) ...[
                AppStyle.vGap8,
                Text(
                  "${controller.pItem.viewNum} 次观看",
                  style: Get.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
