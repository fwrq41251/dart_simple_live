import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/utils.dart';

class DiagnosticService extends GetxService {
  static DiagnosticService get instance => Get.find<DiagnosticService>();

  String platform = '-';
  String roomId = '-';
  String quality = '-';
  String line = '-';
  String urlRequest = '-';
  String recoveryStage = '-';
  String playerError = '-';

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
  }

  void recordRecovery(String stage) => recoveryStage = stage;

  void recordPlayerError(String error) => playerError = error;

  Future<String> buildReport() async {
    var settings = AppSettingsController.instance;
    var report = <String>[
      'Simple Live TV 诊断报告',
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
      '',
      '最近日志:',
      ...(Log.recentLines.isEmpty ? ['-'] : Log.recentLines),
    ].join('\n');
    return DiagnosticRedactor.redact(report);
  }

  Future<File> exportReport() async {
    var root = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    var file = File('${root.path}/simple_live_tv_diagnostic.txt');
    await file.writeAsString(await buildReport(), flush: true);
    return file;
  }

  Future<String> _networkSummary() async {
    try {
      var interfaces = await NetworkInterface.list();
      var names = interfaces.map((item) => item.name.toLowerCase()).toList();
      if (names.any((name) => name.contains('wlan') || name.contains('wifi'))) {
        return 'Wi-Fi';
      }
      if (names.any((name) => name.contains('eth'))) {
        return 'Ethernet';
      }
    } catch (_) {}
    return 'unknown';
  }

  Future<String> _deviceSummary() async {
    try {
      var value = await DeviceInfoPlugin().androidInfo;
      return '${value.manufacturer} ${value.model} (Android ${value.version.release})';
    } catch (_) {
      return 'unknown';
    }
  }
}
