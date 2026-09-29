import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:simple_live_core/src/common/http_client.dart';

/// 测试用 HttpClient：按 URL 关键字返回固化响应，不发起真实网络请求。
///
/// 用法：
/// ```dart
/// HttpClient.instance = MockHttpClient({
///   'searchUser': jsonEncode(...),
/// });
/// ```
/// 恢复真实实现：`HttpClient.instance = null;`
class MockHttpClient implements HttpClient {
  /// URL 关键字 -> 响应体
  final Map<String, String> routes;

  /// 记录收到的请求，便于断言
  final List<String> requests = [];

  MockHttpClient(this.routes);

  @override
  late Dio dio = Dio();

  /// 按 URL 关键字匹配；未匹配时抛错，避免测试静默通过
  String _resolve(String url) {
    requests.add(url);
    for (var key in routes.keys) {
      if (url.contains(key)) {
        return routes[key]!;
      }
    }
    throw Exception('MockHttpClient 未配置该 URL: $url');
  }

  @override
  Future<String> getText(
    String url, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? header,
    CancelToken? cancel,
  }) async {
    return _resolve(url);
  }

  @override
  Future<dynamic> getJson(
    String url, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? header,
    CancelToken? cancel,
  }) async {
    return jsonDecode(_resolve(url));
  }

  @override
  Future<dynamic> postJson(
    String url, {
    Map<String, dynamic>? queryParameters,
    dynamic data,
    Map<String, dynamic>? header,
    bool formUrlEncoded = false,
    CancelToken? cancel,
  }) async {
    return jsonDecode(_resolve(url));
  }

  @override
  Future<Response> head(
    String url, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? header,
    CancelToken? cancel,
  }) async {
    _resolve(url);
    return Response(requestOptions: RequestOptions(path: url));
  }
}

/// 读取 fixtures 文件
String fixture(String name) =>
    File('test/fixtures/douyu/$name').readAsStringSync();
