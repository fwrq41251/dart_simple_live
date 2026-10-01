import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/webdav_recovery.dart';

void main() {
  const all = WebDavRecoverySelection(
    follows: true,
    histories: true,
    blockedWords: true,
    bilibiliAccount: true,
  );

  List<int> backup(Map<String, Object> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      final bytes = utf8.encode(jsonEncode(entry.value));
      archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
    return ZipEncoder().encode(archive);
  }

  test('损坏 ZIP 和 JSON 在提交前失败', () {
    expect(
        () => WebDavRecoveryParser().parse([1, 2, 3], all), throwsA(anything));
    final archive = Archive()
      ..addFile(ArchiveFile(WebDavRecoveryParser.settingsName, 1, [0xff]));
    final malformedJson = ZipEncoder().encode(archive);
    expect(
      () => WebDavRecoveryParser().parse(malformedJson, all),
      throwsA(anything),
    );
  });

  test('列表中任一非法记录会使整个解析失败', () {
    const followsOnly = WebDavRecoverySelection(
      follows: true,
      histories: false,
      blockedWords: false,
      bilibiliAccount: false,
    );
    final bytes = backup({
      WebDavRecoveryParser.followsName: {
        'data': [
          {
            'id': 'site_room',
            'roomId': 'room',
            'siteId': 'site',
            'userName': 'name',
            'face': '',
            'addTime': '2026-01-01 00:00:00.000',
          },
          {'id': 1},
        ],
      },
      WebDavRecoveryParser.tagsName: {'data': <Object>[]},
      WebDavRecoveryParser.settingsName: {'data': <String, Object>{}},
    });

    expect(
      () => WebDavRecoveryParser().parse(bytes, followsOnly),
      throwsA(anything),
    );
  });

  test('成功解析完整备份并为旧标签补充顺序', () {
    final bytes = backup({
      WebDavRecoveryParser.followsName: {
        'data': [
          {
            'id': 'site_room',
            'roomId': 'room',
            'siteId': 'site',
            'userName': 'name',
            'face': '',
            'addTime': '2026-01-01 00:00:00.000',
          }
        ],
      },
      WebDavRecoveryParser.tagsName: {
        'data': [
          {'id': 'tag', 'tag': '标签', 'userId': <String>[]}
        ],
      },
      WebDavRecoveryParser.historiesName: {'data': <Object>[]},
      WebDavRecoveryParser.blockedWordsName: {
        'data': ['  屏蔽词  ']
      },
      WebDavRecoveryParser.bilibiliAccountName: {
        'data': {'cookie': 'cookie'}
      },
      WebDavRecoveryParser.settingsName: {
        'data': {'setting': true}
      },
    });

    final plan = WebDavRecoveryParser().parse(bytes, all);

    expect(plan.follows!.single.id, 'site_room');
    expect(plan.tags!.single.order, 0);
    expect(plan.blockedWords, ['屏蔽词']);
    expect(plan.bilibiliCookie, 'cookie');
    expect(plan.settings, {'setting': true});
  });

  test('提交中途失败会按逆序回滚已尝试步骤', () async {
    final values = <String>['old-first', 'old-second'];
    final events = <String>[];

    await expectLater(
      commitRecovery([
        RecoveryCommitStep(
          apply: () async {
            values[0] = 'new-first';
            events.add('apply-first');
          },
          rollback: () async {
            values[0] = 'old-first';
            events.add('rollback-first');
          },
        ),
        RecoveryCommitStep(
          apply: () async {
            values[1] = 'partly-written';
            events.add('apply-second');
            throw StateError('write failed');
          },
          rollback: () async {
            values[1] = 'old-second';
            events.add('rollback-second');
          },
        ),
      ]),
      throwsStateError,
    );

    expect(values, ['old-first', 'old-second']);
    expect(events, [
      'apply-first',
      'apply-second',
      'rollback-second',
      'rollback-first',
    ]);
  });
}
