import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/services/db_service.dart';

void main() {
  late Directory tempDirectory;
  late DBService service;

  setUp(() async {
    tempDirectory =
        await Directory.systemTemp.createTemp('replay_progress_test');
    Hive.init(tempDirectory.path);
    service = DBService();
    service.replayProgressBox = await Hive.openBox('ReplayProgressTest');
  });

  tearDown(() async {
    await Hive.close();
    await tempDirectory.delete(recursive: true);
  });

  test('保存、读取和删除回放进度', () async {
    await service.saveReplayProgress('douyu_room_replay', 123456);

    expect(service.getReplayProgress('douyu_room_replay'), 123456);

    await service.removeReplayProgress('douyu_room_replay');
    expect(service.getReplayProgress('douyu_room_replay'), isNull);
  });

  test('只保留最近 200 条回放进度', () async {
    for (var i = 0; i <= DBService.maxReplayProgressCount; i++) {
      await service.saveReplayProgress('replay_$i', i * 1000);
    }

    expect(service.replayProgressBox.length, DBService.maxReplayProgressCount);
    expect(
      service.getReplayProgress('replay_${DBService.maxReplayProgressCount}'),
      DBService.maxReplayProgressCount * 1000,
    );
  });
}
