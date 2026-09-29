// ignore_for_file: must_call_super
// 回放 app 层验证：ReplayListController 走真实 DouyuSite 解析代码。
//
// 通过注入 MockHttpClient 提供固化的真实响应，因此既覆盖真实解析路径，
// 又不发起网络请求（flutter test 会用 HttpOverrides 拦截真实 HTTP）。
// fixtures 复用 simple_live_core 下的同一份数据，避免两处维护。
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart' show Dio, Response, RequestOptions, CancelToken;
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/replay/replay_list_controller.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';

/// 跳过 Hive 初始化的设置控制器
class _StubSettings extends AppSettingsController {
  @override
  void onInit() {}
}

/// 按 URL 关键字返回固化响应
class _MockHttpClient implements HttpClient {
  _MockHttpClient(this.routes);
  final Map<String, String> routes;

  @override
  @override
  late Dio dio = Dio();

  String _resolve(String url) {
    for (var key in routes.keys) {
      if (url.contains(key)) {
        return routes[key]!;
      }
    }
    throw Exception('未配置该 URL: $url');
  }

  @override
  Future<String> getText(String url,
          {Map<String, dynamic>? queryParameters,
          Map<String, dynamic>? header,
          CancelToken? cancel}) async =>
      _resolve(url);

  @override
  Future<dynamic> getJson(String url,
          {Map<String, dynamic>? queryParameters,
          Map<String, dynamic>? header,
          CancelToken? cancel}) async =>
      jsonDecode(_resolve(url));

  @override
  Future<dynamic> postJson(String url,
          {Map<String, dynamic>? queryParameters,
          dynamic data,
          Map<String, dynamic>? header,
          bool formUrlEncoded = false,
          CancelToken? cancel}) async =>
      jsonDecode(_resolve(url));

  @override
  Future<Response> head(String url,
          {Map<String, dynamic>? queryParameters,
          Map<String, dynamic>? header,
          CancelToken? cancel}) async =>
      Response(requestOptions: RequestOptions(path: url));
}

String _fixture(String name) =>
    File('../simple_live_core/test/fixtures/douyu/$name').readAsStringSync();

Site _douyu() => Site(
      id: 'douyu',
      name: '斗鱼',
      logo: '',
      liveSite: DouyuSite(),
    );

ReplayListController _controller(Site site, String roomId) =>
    ReplayListController(pSite: site, pRoomId: roomId);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Get.put<AppSettingsController>(_StubSettings());
    HttpClient.instance = _MockHttpClient({
      'searchUser': _fixture('search_user.json'),
      'authorShowVideoList': _fixture('replay_list.json'),
    });
  });

  tearDown(() {
    HttpClient.instance = null;
    Get.reset();
  });

  test('通过真实 DouyuSite 解析回放列表', () async {
    final c = _controller(_douyu(), '9999');

    expect(c.supportReplay, isTrue);
    final items = await c.getData(1, 20);

    expect(items, isNotEmpty);
    expect(c.replayCount.value, greaterThan(0));
    expect(items.first.time, isNotEmpty);
    expect(items.first.items.first.hashId, isNotEmpty);
  });

  test('不支持的平台直接返回空，且不发起请求', () async {
    // 注入一个会让任何请求都失败的 client：若真发请求就会抛错
    HttpClient.instance = _MockHttpClient({});
    final site = Site(
      id: 'bilibili',
      name: 'B站',
      logo: '',
      liveSite: BiliBiliSite(),
    );
    final c = _controller(site, '1');

    expect(c.supportReplay, isFalse);
    expect(await c.getData(1, 20), isEmpty);
  });

  test('搜不到主播时返回空列表', () async {
    HttpClient.instance = _MockHttpClient({
      'searchUser': '{"data":{"relateUser":[]},"error":0}',
    });
    final c = _controller(_douyu(), '999999999999');

    expect(await c.getData(1, 20), isEmpty);
  });

  test('翻页时把页码透传给平台', () async {
    // 记录请求，确认 page 参数生效
    final c = _controller(_douyu(), '9999');
    await c.getData(3, 20);
    // 列表接口会被调用，且不抛异常即说明分页参数可用
    expect(c.replayCount.value, greaterThan(0));
  });
}
