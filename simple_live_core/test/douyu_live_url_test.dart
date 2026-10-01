import 'dart:async';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

class _PartialFailureDouyuSite extends DouyuSite {
  @override
  Future<String> getPlayUrl(
    String roomId,
    String args,
    int rate,
    String cdn,
  ) async {
    if (cdn == 'bad') {
      throw const FormatException('malformed CDN response');
    }
    return 'https://$cdn.example/live.flv';
  }
}

class _ParallelDouyuSite extends DouyuSite {
  final calls = <String>[];
  final slowStarted = Completer<void>();
  final releaseSlow = Completer<void>();

  @override
  Future<String> getPlayUrl(
    String roomId,
    String args,
    int rate,
    String cdn,
  ) async {
    calls.add(cdn);
    if (cdn == 'slow') {
      slowStarted.complete();
      await releaseSlow.future;
    }
    return 'https://$cdn.example/live.flv';
  }
}

LiveRoomDetail _detail() => LiveRoomDetail(
  roomId: '1',
  title: 'test',
  cover: '',
  userName: 'test',
  userAvatar: '',
  online: 1,
  status: true,
  data: 'signed-args',
  url: '',
  isRecord: false,
);

void main() {
  test('getPlayUrls keeps successful CDN URLs when one CDN fails', () async {
    final site = _PartialFailureDouyuSite();
    final quality = LivePlayQuality(
      quality: 'original',
      data: DouyuPlayData(0, ['good', 'bad', 'backup']),
    );

    final result = await site.getPlayUrls(detail: _detail(), quality: quality);

    expect(result.urls, [
      'https://good.example/live.flv',
      'https://backup.example/live.flv',
    ]);
  });

  test(
    'getPlayUrls requests CDN URLs concurrently and preserves order',
    () async {
      final site = _ParallelDouyuSite();
      final quality = LivePlayQuality(
        quality: 'original',
        data: DouyuPlayData(0, ['slow', 'fast']),
      );

      final resultFuture = site.getPlayUrls(
        detail: _detail(),
        quality: quality,
      );
      await site.slowStarted.future;
      await Future<void>.delayed(Duration.zero);

      try {
        expect(site.calls, ['slow', 'fast']);
      } finally {
        site.releaseSlow.complete();
      }

      expect((await resultFuture).urls, [
        'https://slow.example/live.flv',
        'https://fast.example/live.flv',
      ]);
    },
  );

  test('DouyuSignData signs locally with the current room data', () {
    const script = '''
      function ub98484234(roomId, deviceId, timestamp) {
        return 'roomId=' + roomId + '&deviceId=' + deviceId +
            '&timestamp=' + timestamp;
      }
    ''';

    final result = DouyuSignData(script, '12345').toString();

    expect(result, contains('roomId=12345'));
    expect(result, contains('deviceId=10000000000000000000000000001501'));
    expect(result, matches(RegExp(r'&timestamp=\d{10}$')));
  });
}
