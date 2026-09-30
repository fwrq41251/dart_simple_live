import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/replay/replay_controller.dart';

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
    return Obx(() {
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
    if (_playerOverride case final player?) {
      return player;
    }
    return MouseRegion(
      onHover: (_) => controller.showControlsTemporarily(),
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          children: [
            Video(
              key: controller.globalPlayerKey,
              controller: controller.videoController,
              fit: BoxFit.contain,
              controls: (state) => _buildControls(state),
            ),
            if (controller.loading.value)
              const Center(
                child: CircularProgressIndicator(),
              ),
            if (controller.loadError.value)
              Center(
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
              ),
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
        child: Container(
          color: Colors.black26,
          child: Column(
            children: [
              if (controller.showControls.value && controller.fullScreen.value)
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
    return Container(
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
    );
  }
}
