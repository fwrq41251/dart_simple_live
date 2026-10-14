import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'model/live_play_url.dart';

/// A single-player, loopback FLV relay. Network EOF does not end the player's
/// media: reconnect while its existing demuxer buffer is still playing.
///
/// H.264/AAC with unchanged configuration is joined at overlapping packets or
/// a new independent keyframe. Otherwise the caller's normal playback
/// recovery takes over. All network and FLV work runs in a dedicated isolate;
/// URL refresh and notifications stay on the caller's isolate.
/// Signed upstream URLs never leave this session.
class DouyuLiveStream {
  DouyuLiveStream({
    required this.initialUrl,
    required this.refreshUrls,
    this.onEvent,
    this.onFailure,
  });

  final LivePlayUrl initialUrl;
  final Future<LivePlayUrl> Function() refreshUrls;
  final void Function(String event)? onEvent;
  final void Function()? onFailure;
  final Completer<Uri> _ready = Completer<Uri>();
  final Completer<void> _stopped = Completer<void>();
  ReceivePort? _messages;
  SendPort? _commands;
  Future<Isolate>? _launch;
  bool _closed = false;
  bool _failed = false;

  Future<Uri> start() async {
    if (_closed) throw StateError('Stream closed');
    final messages = ReceivePort();
    _messages = messages;
    messages.listen(_handleMessage);
    try {
      _launch = Isolate.spawn(
        _runDouyuStream,
        (messages.sendPort, initialUrl),
        onError: messages.sendPort,
        onExit: messages.sendPort,
        debugName: 'Douyu live relay',
      );
      await _launch;
      final uri = await _ready.future;
      if (_closed) throw StateError('Stream closed');
      return uri;
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<void> close() async {
    _closed = true;
    final launch = _launch;
    if (launch == null) return;
    try {
      await launch;
      await _ready.future;
      // Close sockets explicitly before exiting: killing an isolate alone
      // can leave native sockets open until a later garbage collection.
      _commands?.send(null);
      await _stopped.future;
    } catch (_) {
      // Spawn can fail before an isolate exists to deliver an exit message.
      _messages?.close();
    }
  }

  void _handleMessage(dynamic message) {
    if (message == null) {
      if (!_ready.isCompleted) {
        _ready.completeError(StateError('Live stream worker exited'));
      }
      _stopped.complete();
      _messages?.close();
      if (!_closed) _notifyFailure();
      return;
    }
    switch (message[0]) {
      case 'ready':
        _commands = message[2] as SendPort;
        _ready.complete(message[1] as Uri);
      case 'refresh':
        unawaited(_refresh(message[1] as SendPort));
      case 'event':
        if (!_closed) onEvent?.call(message[1] as String);
      case 'failure':
        if (!_closed) _notifyFailure();
      default:
        // Uncaught isolate errors are [error, stack] messages. Do not expose
        // their text: transport exceptions can contain signed upstream URLs.
        if (!_closed) _notifyFailure();
    }
  }

  void _notifyFailure() {
    // Startup errors are reported by start(), not by playback recovery.
    if (_failed || _commands == null) return;
    _failed = true;
    onFailure?.call();
  }

  Future<void> _refresh(SendPort reply) async {
    if (_closed) return;
    try {
      final urls = await refreshUrls();
      if (!_closed) reply.send(urls);
    } catch (_) {
      if (!_closed) reply.send(null);
    }
  }
}

void _runDouyuStream((SendPort, LivePlayUrl) arguments) async {
  final (messages, initialUrl) = arguments;
  final commands = ReceivePort();
  final relay = _DouyuStreamWorker(
    initialUrl: initialUrl,
    refreshUrls: () async {
      final reply = ReceivePort();
      try {
        messages.send(['refresh', reply.sendPort]);
        final urls = await reply.first as LivePlayUrl?;
        if (urls == null) throw StateError('Live URL refresh failed');
        return urls;
      } finally {
        reply.close();
      }
    },
    onEvent: (event) => messages.send(['event', event]),
    onFailure: () => messages.send(['failure']),
  );
  commands.listen((_) async {
    await relay.close();
    commands.close();
    Isolate.exit();
  });
  try {
    messages.send(['ready', await relay.start(), commands.sendPort]);
  } catch (_) {
    commands.close();
    await relay.close();
    Isolate.exit();
  }
}

class _DouyuStreamWorker {
  _DouyuStreamWorker({
    required this.initialUrl,
    required this.refreshUrls,
    this.onEvent,
    this.onFailure,
  });

  final LivePlayUrl initialUrl;
  final Future<LivePlayUrl> Function() refreshUrls;
  final void Function(String event)? onEvent;
  final void Function()? onFailure;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  HttpServer? _server;
  bool _closed = false;
  bool _connected = false;

  Future<Uri> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    if (_closed) {
      await server.close(force: true);
      throw StateError('Stream closed');
    }
    server.listen((request) => unawaited(_serve(request)));
    return Uri.parse('http://127.0.0.1:${server.port}/live.flv');
  }

  Future<void> close() async {
    _closed = true;
    _client.close(force: true);
    await _server?.close(force: true);
  }

  Future<void> _serve(HttpRequest request) async {
    final output = request.response;
    if (request.uri.path != '/live.flv' ||
        (request.method != 'GET' && request.method != 'HEAD')) {
      output.statusCode = HttpStatus.notFound;
      await output.close();
      return;
    }
    output.headers.contentType = ContentType('video', 'x-flv');
    output.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (request.method == 'HEAD') {
      await output.close();
      return;
    }
    if (_connected || _closed) {
      output.statusCode = HttpStatus.gone;
      await output.close();
      return;
    }
    _connected = true;
    var downstreamClosed = false;
    unawaited(
      output.done.then(
        (_) {
          downstreamClosed = true;
          _client.close(force: true);
        },
        onError: (Object _) {
          downstreamClosed = true;
          _client.close(force: true);
        },
      ),
    );
    final joiner = _FlvJoiner();
    var urls = initialUrl;
    var reconnecting = false;
    final reconnectWatch = Stopwatch();
    try {
      while (!_closed && !downstreamClosed) {
        if (urls.urls.isEmpty) throw const FormatException('No live URL');
        final upstream = await _client.getUrl(Uri.parse(urls.urls.first));
        urls.headers?.forEach(upstream.headers.set);
        final response = await upstream.close();
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException('Live HTTP ${response.statusCode}');
        }
        final reader = _FlvReader(
          response.timeout(const Duration(seconds: 60)),
        );
        var advanced = false;
        try {
          final header = await reader.readHeader();
          joiner.beginConnection(header);
          if (!reconnecting) {
            output.add(header);
            output.add(const [0, 0, 0, 0]);
          }
          var pendingBytes = 0;
          final flushWatch = Stopwatch()..start();
          while (!_closed && !downstreamClosed) {
            final tag = await reader.readTag();
            if (tag == null) break;
            if (!joiner.accept(tag)) continue;
            output.add(tag.bytes);
            pendingBytes += tag.bytes.length;
            if (tag.isFrame) {
              advanced = true;
              if (reconnecting) {
                final mode = joiner.rebased ? '关键帧衔接' : '时间轴衔接';
                onEvent?.call(
                  '连续续流成功（$mode）+${reconnectWatch.elapsedMilliseconds}ms',
                );
                reconnecting = false;
              }
            }
            if (pendingBytes >= 64 * 1024 ||
                flushWatch.elapsedMilliseconds >= 100) {
              await output.flush();
              pendingBytes = 0;
              flushWatch.reset();
            }
          }
          await output.flush();
        } on SocketException {
          if (!advanced) rethrow;
        } on HttpException {
          if (!advanced) rethrow;
        } on TimeoutException {
          if (!advanced) rethrow;
        } finally {
          await reader.cancel();
        }
        if (_closed || downstreamClosed) break;
        // An empty/broken replacement must not cause an unbounded request loop.
        if (!advanced) {
          throw const FormatException('Replacement did not advance');
        }
        onEvent?.call('网络流结束，保留播放器并连接新流');
        reconnectWatch
          ..reset()
          ..start();
        urls = await refreshUrls();
        reconnecting = true;
      }
    } catch (error) {
      if (!_closed && !downstreamClosed) {
        final reason = error is FormatException
            ? error.message
            : error.runtimeType;
        onEvent?.call('连续续流不可用，回退播放器重连（$reason）');
        onFailure?.call();
      }
    } finally {
      try {
        await output.close();
      } catch (_) {
        // Player disposal can close the socket before our upstream completes.
      }
    }
  }
}

class _FlvReader {
  _FlvReader(Stream<List<int>> stream) : _input = StreamIterator(stream);
  final StreamIterator<List<int>> _input;
  List<int> _chunk = const [];
  int _offset = 0;

  Future<Uint8List?> _read(int size) async {
    final bytes = Uint8List(size);
    var written = 0;
    while (written < size) {
      if (_offset == _chunk.length) {
        if (!await _input.moveNext()) return null;
        _chunk = _input.current;
        _offset = 0;
      }
      final count = (size - written).clamp(0, _chunk.length - _offset);
      bytes.setRange(written, written + count, _chunk, _offset);
      written += count;
      _offset += count;
    }
    return bytes;
  }

  Future<Uint8List> readHeader() async {
    final header = await _read(9);
    if (header == null ||
        header[0] != 70 ||
        header[1] != 76 ||
        header[2] != 86 ||
        header[3] != 1 ||
        ByteData.sublistView(header).getUint32(5) != 9) {
      throw const FormatException('Unsupported FLV header');
    }
    final previousSize = await _read(4);
    if (previousSize == null ||
        ByteData.sublistView(previousSize).getUint32(0) != 0) {
      throw const FormatException('Invalid FLV header size');
    }
    return header;
  }

  Future<_FlvTag?> readTag() async {
    final header = await _read(11);
    if (header == null) return null;
    final size = header[1] * 65536 + header[2] * 256 + header[3];
    if (size > 8 * 1024 * 1024 || !const [8, 9, 18].contains(header[0])) {
      throw const FormatException('Unsupported FLV tag');
    }
    // EOF can truncate the last packet. Never forward a partial FLV tag.
    final body = await _read(size + 4);
    if (body == null) return null;
    if (ByteData.sublistView(body).getUint32(size) != size + 11) {
      throw const FormatException('Invalid FLV tag size');
    }
    final bytes = Uint8List(header.length + body.length)
      ..setRange(0, header.length, header)
      ..setRange(header.length, header.length + body.length, body);
    return _FlvTag(bytes);
  }

  Future<void> cancel() => _input.cancel();
}

class _FlvTag {
  _FlvTag(this.bytes);
  final Uint8List bytes;
  int get type => bytes[0];
  int get timestamp =>
      bytes[4] * 65536 + bytes[5] * 256 + bytes[6] + bytes[7] * 16777216;
  set timestamp(int value) {
    bytes[4] = value >> 16;
    bytes[5] = value >> 8;
    bytes[6] = value;
    bytes[7] = value >> 24;
  }

  Uint8List get body => Uint8List.sublistView(bytes, 11, bytes.length - 4);
  bool get isFrame => type != 18 && body.length >= 2 && body[1] == 1;
  bool get isKeyframe => type == 9 && isFrame && body[0] >> 4 == 1;
}

class _FlvJoiner {
  final Map<int, Uint8List> _configs = {};
  final Map<int, int> _last = {};
  final LinkedHashMap<int, String> _videoHistory = LinkedHashMap();
  int? _flags;
  bool _replacement = false;
  bool _verified = false;
  bool _seenVideoConfig = false;
  bool _seenAudioConfig = false;
  int _unverifiedFrames = 0;
  int _timestampOffset = 0;
  int _videoStep = 40;
  int? _lastSourceVideo;
  bool rebased = false;

  void beginConnection(Uint8List header) {
    if (_flags != null && _flags != header[4]) {
      throw const FormatException('FLV tracks changed');
    }
    _replacement = _flags != null;
    _flags = header[4];
    _verified = !_replacement;
    _seenVideoConfig = false;
    _seenAudioConfig = header[4] & 4 == 0;
    _unverifiedFrames = 0;
    rebased = false;
  }

  bool accept(_FlvTag tag) {
    if (tag.type == 18) return !_replacement;
    final body = tag.body;
    if (body.length < 2 ||
        (tag.type == 9 ? body[0] & 15 != 7 : body[0] >> 4 != 10)) {
      throw const FormatException('Only AVC/AAC can be joined');
    }
    if (body[1] == 0) {
      final previous = _configs[tag.type];
      if (previous != null &&
          sha256.convert(previous) != sha256.convert(body)) {
        throw const FormatException('Codec configuration changed');
      }
      _configs[tag.type] = body;
      if (tag.type == 9) _seenVideoConfig = true;
      if (tag.type == 8) _seenAudioConfig = true;
      return !_replacement;
    }
    // Do not forward AVC end-of-sequence markers across network connections.
    if (!tag.isFrame) return false;
    if (!_seenVideoConfig || !_seenAudioConfig) {
      throw const FormatException('Missing codec configuration');
    }
    final last = _last[tag.type];
    final sourceTimestamp = tag.timestamp;
    if (!_verified) {
      if (tag.type != 9) return false;
      if (++_unverifiedFrames > 600) {
        throw const FormatException('No overlapping video frames');
      }
      final fingerprint = sha256.convert(body).toString();
      if (_videoHistory[tag.timestamp] == fingerprint) {
        _verified = true;
      } else if (tag.timestamp > (_lastSourceVideo ?? -1) && tag.isKeyframe) {
        // No overlapping reference frames: skip inter-frames until an IDR.
        // Missing content cannot be recovered, but do not turn that missing
        // interval into a frozen picture. Shift both tracks by the same amount
        // to preserve A/V sync and continue the existing decoder at this IDR.
        final videoNext = _last[9]! + _videoStep;
        final audioNext = (_last[8] ?? -1) + 1;
        final next = videoNext > audioNext ? videoNext : audioNext;
        _timestampOffset = next - sourceTimestamp;
        _verified = true;
        rebased = true;
      } else {
        return false;
      }
    }
    final timestamp = sourceTimestamp + _timestampOffset;
    if (last != null && timestamp <= last) return false;
    _last[tag.type] = timestamp;
    if (tag.type == 9) {
      if (last != null && timestamp - last <= 100) {
        _videoStep = timestamp - last;
      }
      _lastSourceVideo = sourceTimestamp;
      _videoHistory[sourceTimestamp] = sha256.convert(body).toString();
      // Fingerprints, not frame payloads: fixed memory even for high bitrates.
      while (_videoHistory.length > 600) {
        _videoHistory.remove(_videoHistory.keys.first);
      }
    }
    tag.timestamp = timestamp;
    return true;
  }
}
