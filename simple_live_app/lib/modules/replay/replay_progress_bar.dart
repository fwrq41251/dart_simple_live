import 'dart:math' as math;

import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 悬停/拖动只更新预览，释放滑块后才改变播放位置。
class ReplayProgressBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final LiveReplayPreview? preview;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<bool> onInteraction;
  final GlobalKey? playerKey;

  const ReplayProgressBar({
    required this.position,
    required this.duration,
    required this.onSeek,
    required this.onInteraction,
    this.preview,
    this.playerKey,
    super.key,
  });

  @override
  State<ReplayProgressBar> createState() => _ReplayProgressBarState();
}

class _ReplayProgressBarState extends State<ReplayProgressBar> {
  double? _dragValue;
  double? _hoverValue;
  double _previewHeight = 80;

  @override
  void dispose() {
    // 切换全屏/布局时 MouseRegion 被移除不会触发 onExit。
    if (_dragValue != null || _hoverValue != null) {
      final onInteraction = widget.onInteraction;
      WidgetsBinding.instance.addPostFrameCallback((_) => onInteraction(false));
    }
    super.dispose();
  }

  void _updatePreviewHeight() {
    final player = widget.playerKey?.currentContext?.findRenderObject();
    final progress = context.findRenderObject();
    if (player is RenderBox && progress is RenderBox) {
      // 按实际底栏位置计算，底部按钮换行时也不能把预览裁出画面。
      final space = progress.localToGlobal(Offset.zero).dy -
          player.localToGlobal(Offset.zero).dy;
      final labelHeight = MediaQuery.textScalerOf(context).scale(12) * 1.5;
      // 浮窗距滑块底部 40px；另留 8px 内边距和 8px 顶部间距。
      _previewHeight = (space + progress.size.height - 40 - 16 - labelHeight)
          .clamp(0.0, 80.0);
      if (_previewHeight < 24) _previewHeight = 0;
    }
  }

  Duration _timeAt(double value) => Duration(
        milliseconds: (widget.duration.inMilliseconds * value).round(),
      );

  @override
  Widget build(BuildContext context) {
    final enabled = widget.duration > Duration.zero;
    final value = enabled
        ? (widget.position.inMilliseconds / widget.duration.inMilliseconds)
            .clamp(0.0, 1.0)
        : 0.0;
    final previewValue = enabled ? _dragValue ?? _hoverValue : null;
    return LayoutBuilder(builder: (context, constraints) {
      // 固定轨道内边距，让鼠标时间映射与 Slider 的实际轨道一致。
      const inset = 16.0;
      final trackWidth = math.max(1.0, constraints.maxWidth - inset * 2);
      final cardWidth = math.min(160.0, constraints.maxWidth);
      final time = previewValue == null ? null : _timeAt(previewValue);
      final frame = time == null ? null : widget.preview?.frameAt(time);
      return MouseRegion(
        onHover: enabled
            ? (event) {
                _updatePreviewHeight();
                setState(() {
                  _hoverValue = ((event.localPosition.dx - inset) / trackWidth)
                      .clamp(0.0, 1.0);
                });
                widget.onInteraction(true);
              }
            : null,
        onExit: (_) {
          setState(() => _hoverValue = null);
          if (_dragValue == null) widget.onInteraction(false);
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Slider(
              padding: const EdgeInsets.symmetric(horizontal: inset),
              value: _dragValue ?? value,
              onChangeStart: enabled
                  ? (v) {
                      _updatePreviewHeight();
                      setState(() => _dragValue = v);
                      widget.onInteraction(true);
                    }
                  : null,
              onChanged: enabled ? (v) => setState(() => _dragValue = v) : null,
              onChangeEnd: enabled
                  ? (v) {
                      setState(() {
                        _dragValue = null;
                        _hoverValue = null;
                      });
                      widget.onInteraction(false);
                      widget.onSeek(_timeAt(v));
                    }
                  : null,
            ),
            if (time != null)
              Positioned(
                bottom: 40,
                left: (inset + trackWidth * previewValue! - cardWidth / 2)
                    .clamp(0.0, constraints.maxWidth - cardWidth),
                width: cardWidth,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (frame != null && _previewHeight > 0)
                          ExtendedImage.network(
                            frame.url,
                            cache: true,
                            loadStateChanged: (state) {
                              final image = state.extendedImageInfo?.image;
                              if (state.extendedImageLoadState !=
                                      LoadState.completed ||
                                  image == null) {
                                // 无图片时仍显示目标时间，不显示错误占位图。
                                return const SizedBox.shrink();
                              }
                              final width = math.min(
                                cardWidth - 8,
                                _previewHeight * image.width / image.height,
                              );
                              final height = width * image.height / image.width;
                              return SizedBox(
                                width: width,
                                height: height,
                                child: Stack(
                                  clipBehavior: Clip.hardEdge,
                                  children: [
                                    Positioned(
                                      left: -frame.column * width,
                                      top: -frame.row * height,
                                      width: width * 10,
                                      height: height * 10,
                                      child: RawImage(
                                        image: image,
                                        fit: BoxFit.fill,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        Text(
                          Utils.formatDuration(time),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    });
  }
}
