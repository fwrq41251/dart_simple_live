import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';

void main() {
  late Directory tempDirectory;
  late DBService service;

  setUpAll(() {
    Hive.registerAdapter(FollowUserAdapter());
    Hive.registerAdapter(HistoryAdapter());
    Hive.registerAdapter(FollowUserTagAdapter());
  });

  setUp(() async {
    tempDirectory =
        await Directory.systemTemp.createTemp('replay_progress_test');
    Hive.init(tempDirectory.path);
    service = DBService();
    await service.init();
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

  test('排序后仍可修改和删除标签', () async {
    final first = await service.addFollowTag('一');
    final second = await service.addFollowTag('二');

    await service.updateFollowTagOrder([second, first]);
    expect(
        service.getFollowTagList().map((tag) => tag.id), [second.id, first.id]);
    expect(service.tagBox.keys.toSet(), {second.id, first.id});

    await service.updateFollowTag(second.copyWith(tag: '修改'));
    expect(service.getFollowTagList().first.tag, '修改');
    await service.deleteFollowTag(first.id);
    expect(service.getFollowTagList().map((tag) => tag.id), [second.id]);
  });

  test('排序后重新打开仍按原顺序读取', () async {
    final first = await service.addFollowTag('一');
    final second = await service.addFollowTag('二');
    await service.updateFollowTagOrder([second, first]);

    await service.tagBox.close();
    service.tagBox = await Hive.openBox<FollowUserTag>('FollowUserTag');

    expect(
        service.getFollowTagList().map((tag) => tag.id), [second.id, first.id]);
  });

  test('启动时迁移旧整数 key 并去除同 id 重复项', () async {
    final first = FollowUserTag(id: 'first', tag: '一', userId: []);
    final staleSecond = FollowUserTag(id: 'second', tag: '旧名称', userId: []);
    final currentSecond =
        FollowUserTag(id: 'second', tag: '新名称', userId: ['user']);
    await service.tagBox.clear();
    await service.tagBox.putAll({0: first, 1: staleSecond});
    await service.tagBox.put(currentSecond.id, currentSecond);
    await Hive.close();

    service = DBService();
    await service.init();

    expect(service.tagBox.keys, ['first', 'second']);
    expect(
        service.getFollowTagList().map((tag) => tag.id), ['first', 'second']);
    expect(service.getFollowTagList().last.tag, '新名称');
    expect(service.getFollowTagList().last.userId, ['user']);
  });

  test('重复名称返回已有标签且不新增', () async {
    final original = await service.addFollowTag('重复');

    final duplicate = await service.addFollowTag('重复');

    expect(duplicate.id, original.id);
    expect(service.tagBox.length, 1);
  });

  test('超过 8 个字符的名称抛出参数错误且不新增', () async {
    expect(
      () => service.addFollowTag('123456789'),
      throwsArgumentError,
    );
    expect(service.tagBox, isEmpty);
  });

  test('标签 JSON 保留排序并兼容旧数据', () {
    final tag = FollowUserTag(
      id: 'tag',
      tag: '标签',
      userId: ['user'],
      order: 3,
    );

    expect(FollowUserTag.fromJson(tag.toJson()).order, 3);
    expect(
      FollowUserTag.fromJson({
        'id': 'legacy',
        'tag': '旧标签',
        'userId': <String>[],
      }).order,
      isNull,
    );
  });
}
