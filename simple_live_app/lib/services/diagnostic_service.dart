import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_core/simple_live_core.dart';

class DiagnosticService extends GetxService {
  static DiagnosticService get instance => Get.find<DiagnosticService>();

  String platform = '-';
  String roomId = '-';
  String quality = '-';
  String line = '-';
  String urlRequest = '-';
  String recoveryStage = '-';
  String playerError = '-';
  final List<String> _events = [];

  void updateRoom({
    required String platform,
    required String roomId,
    String? quality,
    String? line,
  }) {
    this.platform = platform;
    this.roomId = roomId;
    this.quality = quality ?? this.quality;
    this.line = line ?? this.line;
  }

  void recordUrlRequest(Duration elapsed, String result) {
    urlRequest = '${elapsed.inMilliseconds}ms ($result)';
    addEvent('播放地址请求: $urlRequest');
  }

  void recordRecovery(String stage) {
    recoveryStage = stage;
    addEvent('恢复阶段: $stage');
  }

  void recordPlayerError(String error) {
    playerError = error;
    addEvent('播放器错误: $error');
  }

  void addEvent(String event) {
    _events.add('${DateTime.now().toIso8601String()} $event');
    if (_events.length > 30) {
      _events.removeAt(0);
    }
  }

  Future<String> buildReport() async {
    var settings = AppSettingsController.instance;
    var lines = <String>[
      'Simple Live 诊断报告',
      '生成时间: ${DateTime.now().toIso8601String()}',
      '应用版本: ${Utils.packageInfo.version}+${Utils.packageInfo.buildNumber}',
      '系统: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      '设备: ${await _deviceSummary()}',
      '网络: ${await _networkSummary()}',
      '',
      '直播平台: $platform',
      '房间号: $roomId',
      '清晰度: $quality',
      '线路: $line',
      '播放地址请求: $urlRequest',
      '恢复阶段: $recoveryStage',
      '播放器错误: $playerError',
      '',
      '硬件解码: ${settings.hardwareDecode.value}',
      '兼容模式: ${settings.playerCompatMode.value}',
      '自定义输出: ${settings.customPlayerOutput.value}',
      '视频输出: ${settings.videoOutputDriver.value}',
      '硬件解码器: ${settings.videoHardwareDecoder.value}',
      '音频输出: ${settings.audioOutputDriver.value}',
      '缓冲区: ${settings.playerBufferSize.value} MB',
      '网络超时: 60 秒',
      '',
      '最近事件:',
      ...(_events.isEmpty ? ['-'] : _events),
    ];
    return DiagnosticRedactor.redact(lines.join('\n'));
  }

  Future<String> _networkSummary() async {
    try {
      var values = await Connectivity().checkConnectivity();
      return values.map((value) => value.name).join(', ');
    } catch (_) {
      return 'unknown';
    }
  }

  Future<String> _deviceSummary() async {
    try {
      var info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        var value = await info.androidInfo;
        return '${value.manufacturer} ${value.model} (Android ${value.version.release})';
      }
      if (Platform.isIOS) {
        var value = await info.iosInfo;
        return '${value.utsname.machine} (iOS ${value.systemVersion})';
      }
      if (Platform.isLinux) {
        var value = await info.linuxInfo;
        return '${value.prettyName} ${value.version ?? ''}'.trim();
      }
      if (Platform.isMacOS) {
        var value = await info.macOsInfo;
        return '${value.model} ${value.osRelease}';
      }
      if (Platform.isWindows) {
        var value = await info.windowsInfo;
        return '${value.productName} ${value.displayVersion}';
      }
    } catch (_) {}
    return 'unknown';
  }
}
