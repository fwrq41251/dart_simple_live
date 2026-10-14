import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

const _header = [70, 76, 86, 1, 5, 0, 0, 0, 9, 0, 0, 0, 0];
List<int> _tag(int type, int timestamp, List<int> body) {
  final header = Uint8List(11);
  header[0] = type;
  header[1] = body.length >> 16;
  header[2] = body.length >> 8;
  header[3] = body.length;
  header[4] = timestamp >> 16;
  header[5] = timestamp >> 8;
  header[6] = timestamp;
  header[7] = timestamp >> 24;
  final previous = ByteData(4)..setUint32(0, body.length + 11);
  return [...header, ...body, ...previous.buffer.asUint8List()];
}

List<int> _config({int video = 1}) => [
  ..._tag(18, 0, [1, 2, 3]),
  ..._tag(8, 0, [0xaf, 0, 0x12, 0x10]),
  ..._tag(9, 0, [0x17, 0, 0, 0, 0, video]),
];
List<int> _video(int ts, int id, {bool keyframe = false}) =>
    _tag(9, ts, [keyframe ? 0x17 : 0x27, 1, 0, 0, 0, id]);
List<int> _audio(int ts, int id) => _tag(8, ts, [0xaf, 1, id]);

void main() {
  late io.HttpServer source;
  late io.HttpClient player;
  DouyuLiveStream? relay;
  var requests = 0;
  var failures = 0;
  var refreshes = 0;
  var brokenTransport = false;
  late List<List<int>> connections;
  late Uri sourceUri;

  setUp(() async {
    source = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    sourceUri = Uri.parse('http://127.0.0.1:${source.port}/signed.flv');
    player = io.HttpClient();
    requests = failures = refreshes = 0;
    brokenTransport = false;
    connections = [];
    source.listen((request) async {
      final bytes = connections[requests++];
      final disconnect = brokenTransport && requests == 1;
      expect(request.headers.value('x-stream-test'), 'upstream-only');
      if (disconnect) {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.write(
          'HTTP/1.1 200 OK\r\nContent-Length: ${bytes.length + 100}\r\n\r\n',
        );
        socket.add(bytes);
        await socket.flush();
        socket.destroy();
        return;
      }
      // Split inside FLV headers, bodies and PreviousTagSize fields.
      for (var offset = 0; offset < bytes.length; offset += 7) {
        request.response.add(
          bytes.sublist(offset, (offset + 7).clamp(0, bytes.length)),
        );
        await request.response.flush();
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await relay?.close();
    relay = null;
    player.close(force: true);
    await source.close(force: true);
  });

  Future<List<int>> play() async {
    final urls = LivePlayUrl(
      urls: [sourceUri.toString()],
      headers: {'x-stream-test': 'upstream-only'},
    );
    relay = DouyuLiveStream(
      initialUrl: urls,
      refreshUrls: () async {
        refreshes++;
        return requests < connections.length ? urls : LivePlayUrl(urls: []);
      },
      onFailure: () => failures++,
    );
    final response = await (await player.getUrl(await relay!.start())).close();
    expect(response.statusCode, 200);
    expect(response.headers.value('x-stream-test'), isNull);
    return response.fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
  }

  test(
    'one FLV response joins overlapping audio/video without duplicating headers or frames',
    () async {
      // Exercise the extended timestamp byte, asymmetric audio/video clocks,
      // and an inter-frame (not a keyframe) as the first new video packet.
      const base = 0x1000000;
      final first = [
        ..._header,
        ..._config(),
        ..._video(base + 2000, 1, keyframe: true),
        ..._audio(base + 2011, 1),
        ..._video(base + 2040, 2),
        ..._audio(base + 2057, 2),
      ];
      final continuation = [
        ..._video(base + 2080, 3),
        ..._audio(base + 2103, 3),
        ..._video(base + 2120, 4),
      ];
      connections = [
        first,
        [
          ..._header,
          ..._config(),
          ..._video(base + 2000, 1, keyframe: true),
          ..._audio(base + 2011, 1),
          ..._video(base + 2040, 2),
          ..._audio(base + 2057, 2),
          ...continuation,
        ],
      ];
      expect(await play(), [...first, ...continuation]);
      expect(requests, 2);
      expect(refreshes, 2);
      expect(
        failures,
        1,
      ); // Empty URL list at the end hands off to normal recovery.
    },
  );

  test(
    'missing reference frames join at a keyframe with one shared A/V offset across subsequent reconnects',
    () async {
      final first = [
        ..._header,
        ..._config(),
        ..._video(2000, 1, keyframe: true),
        ..._audio(2011, 1),
        ..._video(2040, 2),
        ..._audio(2057, 2),
      ];
      connections = [
        first,
        [
          ..._header,
          ..._config(),
          ..._video(6000, 3),
          ..._audio(6003, 3),
          ..._video(7000, 4, keyframe: true),
          ..._audio(7009, 4),
          ..._video(7040, 5),
          ..._audio(7055, 5),
        ],
        [
          ..._header,
          ..._config(),
          ..._video(7000, 4, keyframe: true),
          ..._audio(7009, 4),
          ..._video(7040, 5),
          ..._audio(7055, 5),
          ..._video(7080, 6),
          ..._audio(7101, 6),
        ],
      ];
      // Last video step is 40ms: 7000 maps to 2080, a -4920ms offset
      // applied to both tracks. The third connection must retain this offset.
      expect(await play(), [
        ...first,
        ..._video(2080, 4, keyframe: true),
        ..._audio(2089, 4),
        ..._video(2120, 5),
        ..._audio(2135, 5),
        ..._video(2160, 6),
        ..._audio(2181, 6),
      ]);
      expect(requests, 3);
    },
  );

  test(
    'codec changes, unrelated inter-frames and reset clocks fall back without corrupting the old stream',
    () async {
      final first = [
        ..._header,
        ..._config(),
        ..._video(5000, 1, keyframe: true),
        ..._audio(5011, 1),
      ];
      for (final replacement in [
        [..._config(video: 2), ..._video(5040, 2)],
        [..._config(), ..._video(5040, 99)],
        [..._config(), ..._video(0, 99, keyframe: true), ..._video(40, 98)],
      ]) {
        connections = [
          first,
          [..._header, ...replacement],
        ];
        requests = failures = refreshes = 0;
        expect(await play(), first);
        expect(failures, 1);
        expect(requests, 2);
        await relay!.close();
      }
    },
  );

  test(
    'a truncated final tag is dropped and the next connection supplies the complete packet',
    () async {
      final first = [
        ..._header,
        ..._config(),
        ..._video(2000, 1, keyframe: true),
        ..._audio(2011, 1),
      ];
      final next = _video(2040, 2);
      connections = [
        [...first, ...next.take(14)],
        [...first, ...next, ..._audio(2057, 2)],
      ];
      for (final broken in [false, true]) {
        brokenTransport = broken;
        requests = failures = refreshes = 0;
        expect(await play(), [...first, ...next, ..._audio(2057, 2)]);
        expect(requests, 2);
        await relay!.close();
      }
    },
  );

  test(
    'closing during URL refresh prevents a late replacement connection',
    () async {
      final pending = Completer<LivePlayUrl>();
      final refreshing = Completer<void>();
      connections = [
        [
          ..._header,
          ..._config(),
          ..._video(2000, 1, keyframe: true),
          ..._audio(2011, 1),
        ],
      ];
      relay = DouyuLiveStream(
        initialUrl: LivePlayUrl(
          urls: [sourceUri.toString()],
          headers: {'x-stream-test': 'upstream-only'},
        ),
        refreshUrls: () {
          refreshing.complete();
          return pending.future;
        },
        onFailure: () => failures++,
      );
      final response = await (await player.getUrl(
        await relay!.start(),
      )).close();
      final drained = response.drain<void>().catchError((Object _) {});
      await refreshing.future;
      await relay!.close();
      pending.complete(LivePlayUrl(urls: [sourceUri.toString()]));
      await drained;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(requests, 1);
      expect(failures, 0);
    },
  );
}
