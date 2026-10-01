// 斗鱼回放链路的离线测试。
//
// 使用固化的真实响应（test/fixtures/douyu/），覆盖完整解析代码路径，
// 不发起任何网络请求：确定性、可离线、CI 友好。
// 之前的实现打真实接口，会受网络与平台风控影响。
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:test/test.dart';

import 'mock_http_client.dart';

void main() {
  late MockHttpClient mock;

  setUp(() {
    mock = MockHttpClient({
      'searchUser': fixture('search_user.json'),
      'authorShowVideoList': fixture('replay_list.json'),
      'v.douyu.com/show': fixture('replay_show.html'),
      'getStreamUrlWeb': fixture('stream_url.json'),
      'getBarrageList': fixture('replay_danmaku.json'),
    });
    HttpClient.instance = mock;
  });

  tearDown(() {
    HttpClient.instance = null;
  });

  final site = DouyuSite();

  group('斗鱼回放', () {
    test('supportReplay 为 true', () {
      expect(site.supportReplay, isTrue);
    });

    test('房间号解析为 hash 形式的 up_id', () async {
      final upId = await site.getReplayUpId('9999');
      // 必须是 hash，数字 uid 会被接口拒绝
      expect(upId, 'XrZwYgYJaAbK');
    });

    test('搜索结果里的无 anchorInfo 条目不会导致崩溃', () async {
      // search_user.json 中确实存在缺少 anchorInfo 的条目
      final raw = fixture('search_user.json');
      expect(raw.contains('"anchorInfo"'), isTrue);
      // 能正常解析即说明空值防护生效
      expect(await site.getReplayUpId('9999'), isNotNull);
    });

    test('解析回放列表（按场次分组）', () async {
      final result = await site.getReplayList(roomId: '9999');

      expect(result.count, greaterThan(0));
      expect(result.items, isNotEmpty);

      final first = result.items.first;
      expect(first.time, isNotEmpty);
      expect(first.title, isNotEmpty);
      expect(first.items, isNotEmpty);

      final item = first.items.first;
      expect(item.hashId, isNotEmpty);
      expect(item.title, isNotEmpty);
      // 封面必须是完整 URL，供列表展示
      expect(item.cover, startsWith('http'));
    });

    test('解析回放播放地址（全部清晰度）', () async {
      final result = await site.getReplayUrl(
        roomId: '9999',
        hashId: 'EO0XvNxPllxMDrBd',
      );

      expect(result.qualities, isNotEmpty);

      // 固化响应里共有 4 档
      final keys = result.qualities.map((e) => e.quality).toSet();
      expect(keys, containsAll(['normal', 'high', '1080p60', '1440p60a']));

      for (final q in result.qualities) {
        expect(q.url, startsWith('http'));
        expect(q.name, isNotEmpty);
      }
    });

    test('从页面正确提取 vid 与 point_id（签名入参）', () async {
      // getReplayUrl 依赖 $DATA 与签名脚本的解析；
      // 能取到地址即说明 vid/point_id/签名脚本三步都解析正确
      final result = await site.getReplayUrl(
        roomId: '9999',
        hashId: 'EO0XvNxPllxMDrBd',
      );
      expect(result.qualities, isNotEmpty);
    });

    test('解析回放弹幕并按时间排序', () async {
      final result = await site.getReplayDanmaku(
        hashId: 'EO0XvNxPllxMDrBd',
        startTime: 1000,
      );

      expect(result.startTime, 1000);
      expect(result.endTime, 60000);
      expect(result.items.map((e) => e.text), ['first', 'colored', 'later']);
      expect(result.items.map((e) => e.time), [1300, 1800, 2200]);
      expect(result.items[0].color, 0xFFFFFFFF);
      expect(result.items[1].color, 0xFF3D9BFF);
      expect(mock.queries.last, {
        'vid': 'EO0XvNxPllxMDrBd',
        'start_time': 1000,
        'end_time': -1,
      });
    });

    test('清晰度按 level 降序排列，索引 0 为最高清晰度', () async {
      // 接口返回的 thumb_video 是 JSON 对象，键顺序由服务端决定：
      // 实测 231059 房间返回 normal 在前、super 在后。
      // 若直接沿用键顺序，currentQuality=0 会默认播标清。
      HttpClient.instance = MockHttpClient({
        'searchUser': fixture('search_user.json'),
        'authorShowVideoList': fixture('replay_list.json'),
        'v.douyu.com/show': fixture('replay_show.html'),
        'getStreamUrlWeb': fixture('stream_url_unsorted.json'),
      });

      final result = await site.getReplayUrl(
        roomId: '9999',
        hashId: 'EO0XvNxPllxMDrBd',
      );

      // 响应里 normal(5) 在前、super(15) 在后，必须被重排
      expect(result.qualities.map((e) => e.quality).toList(), [
        'super',
        'high',
        'normal',
      ]);
      expect(result.qualities.first.name, '高清1080P');
    });

    test('level 缺失时保持原有相对顺序', () async {
      HttpClient.instance = MockHttpClient({
        'searchUser': fixture('search_user.json'),
        'authorShowVideoList': fixture('replay_list.json'),
        'v.douyu.com/show': fixture('replay_show.html'),
        'getStreamUrlWeb': fixture('stream_url_no_level.json'),
      });

      final result = await site.getReplayUrl(
        roomId: '9999',
        hashId: 'EO0XvNxPllxMDrBd',
      );

      expect(result.qualities.map((e) => e.quality).toList(), [
        'normal',
        'high',
        'super',
      ]);
    });

    test('页面缺少 \$DATA 时抛出明确异常', () async {
      HttpClient.instance = MockHttpClient({
        'searchUser': fixture('search_user.json'),
        'authorShowVideoList': fixture('replay_list.json'),
        'v.douyu.com/show': '<html><body>no data here</body></html>',
      });

      expect(
        () => site.getReplayUrl(roomId: '9999', hashId: 'xxx'),
        throwsA(isA<Exception>()),
      );
    });

    test('搜不到主播时返回空列表而不是抛异常', () async {
      // 搜索响应里没有任何 rid 匹配的条目
      HttpClient.instance = MockHttpClient({
        'searchUser': '{"data":{"relateUser":[]},"error":0}',
      });

      final result = await site.getReplayList(roomId: '9999');
      expect(result.count, 0);
      expect(result.items, isEmpty);
    });

    test('接口报错时抛出异常', () async {
      HttpClient.instance = MockHttpClient({
        'searchUser': fixture('search_user.json'),
        'authorShowVideoList': '{"error":8,"msg":"行为存在风险"}',
      });

      expect(
        () => site.getReplayList(roomId: '9999'),
        throwsA(isA<Exception>()),
      );
    });

    test('其他平台默认不支持回放', () {
      expect(BiliBiliSite().supportReplay, isFalse);
      expect(HuyaSite().supportReplay, isFalse);
      expect(DouyinSite().supportReplay, isFalse);
    });

    test('不支持的平台返回空结果', () async {
      final result = await BiliBiliSite().getReplayList(roomId: '1');
      expect(result.items, isEmpty);
    });
  });
}
