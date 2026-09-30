import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/danmaku/douyu_danmaku.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/interface/live_site.dart';
import 'package:simple_live_core/src/model/live_anchor_item.dart';
import 'package:simple_live_core/src/model/live_category.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:simple_live_core/src/model/live_room_item.dart';
import 'package:simple_live_core/src/model/live_search_result.dart';
import 'package:simple_live_core/src/model/live_room_detail.dart';
import 'package:simple_live_core/src/model/live_play_quality.dart';
import 'package:simple_live_core/src/model/live_category_result.dart';
import 'package:simple_live_core/src/model/live_replay.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:simple_live_core/src/scripts/douyu_sign.dart';

class DouyuSite implements LiveSite {
  @override
  String id = "douyu";

  @override
  String name = "斗鱼直播";

  @override
  LiveDanmaku getDanmaku() => DouyuDanmaku();

  @override
  Future<List<LiveCategory>> getCategores() async {
    List<LiveCategory> categories = [];
    var result = await HttpClient.instance.getJson(
      "https://m.douyu.com/api/cate/list",
    );
    var subCateList = result["data"]["cate2Info"] as List;
    for (var item in result["data"]["cate1Info"]) {
      var cate1Id = item["cate1Id"];
      var cate1Name = item["cate1Name"];
      List<LiveSubCategory> subCategories = [];
      subCateList.where((x) => x["cate1Id"] == cate1Id).forEach((element) {
        subCategories.add(
          LiveSubCategory(
            pic: element["icon"],
            id: element["cate2Id"].toString(),
            parentId: cate1Id.toString(),
            name: element["cate2Name"].toString(),
          ),
        );
      });
      categories.add(
        LiveCategory(
          id: cate1Id.toString(),
          name: cate1Name.toString(),
          children: subCategories,
        ),
      );
    }
    // 根据ID排序
    categories.sort((a, b) => int.parse(a.id).compareTo(int.parse(b.id)));

    return categories;
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) async {
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/gapi/rkc/directory/mixList/2_${category.id}/$page",
      queryParameters: {},
    );

    var items = <LiveRoomItem>[];
    for (var item in result['data']['rl']) {
      if (item["type"] != 1) {
        continue;
      }
      var roomItem = LiveRoomItem(
        cover: item['rs16'].toString(),
        online: item['ol'],
        roomId: item['rid'].toString(),
        title: item['rn'].toString(),
        userName: item['nn'].toString(),
      );
      items.add(roomItem);
    }
    var hasMore = page < result['data']['pgcnt'];
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    var data = detail.data.toString();
    data += "&cdn=&rate=-1&ver=Douyu_223061205&iar=1&ive=1&hevc=0&fa=0";
    List<LivePlayQuality> qualities = [];
    var result = await HttpClient.instance.postJson(
      "https://www.douyu.com/lapi/live/getH5Play/${detail.roomId}",
      data: data,
      formUrlEncoded: true,
    );

    var cdns = <String>[];
    for (var item in result["data"]["cdnsWithName"]) {
      cdns.add(item["cdn"].toString());
    }

    // 如果cdn以scdn开头，将其放到最后
    cdns.sort((a, b) {
      if (a.startsWith("scdn") && !b.startsWith("scdn")) {
        return 1;
      } else if (!a.startsWith("scdn") && b.startsWith("scdn")) {
        return -1;
      }
      return 0;
    });

    for (var item in result["data"]["multirates"]) {
      qualities.add(
        LivePlayQuality(
          quality: item["name"].toString(),
          data: DouyuPlayData(item["rate"], cdns),
        ),
      );
    }
    return qualities;
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    var args = detail.data.toString();
    var data = quality.data as DouyuPlayData;

    List<String> urls = [];
    for (var item in data.cdns) {
      var url = await getPlayUrl(detail.roomId, args, data.rate, item);
      if (url.isNotEmpty) {
        urls.add(url);
      }
    }
    return LivePlayUrl(urls: urls);
  }

  Future<String> getPlayUrl(
    String roomId,
    String args,
    int rate,
    String cdn,
  ) async {
    args += "&cdn=$cdn&rate=$rate";
    var result = await HttpClient.instance.postJson(
      "https://www.douyu.com/lapi/live/getH5Play/$roomId",
      data: args,
      header: {
        'referer': 'https://www.douyu.com/$roomId',
        'user-agent':
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.43",
      },
      formUrlEncoded: true,
    );

    return "${result["data"]["rtmp_url"]}/${HtmlUnescape().convert(result["data"]["rtmp_live"].toString())}";
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/weblist/apinc/allpage/6/$page",
      queryParameters: {},
    );

    var items = <LiveRoomItem>[];
    for (var item in result['data']['rl']) {
      if (item["type"] != 1) {
        continue;
      }
      var roomItem = LiveRoomItem(
        cover: item['rs16'].toString(),
        online: item['ol'],
        roomId: item['rid'].toString(),
        title: item['rn'].toString(),
        userName: item['nn'].toString(),
      );
      items.add(roomItem);
    }
    var hasMore = page < result['data']['pgcnt'];
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    Map roomInfo = await _getRoomInfo(roomId);

    Map h5RoomInfo = await HttpClient.instance.getJson(
      "https://www.douyu.com/swf_api/h5room/$roomId",
      queryParameters: {},
      header: {
        'referer': 'https://www.douyu.com/$roomId',
        'user-agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.43',
      },
    );
    String? showTime = h5RoomInfo["data"]?["show_time"]?.toString();

    var jsEncResult = await HttpClient.instance.getText(
      "https://www.douyu.com/swf_api/homeH5Enc?rids=$roomId",
      queryParameters: {},
      header: {
        'referer': 'https://www.douyu.com/$roomId',
        'user-agent':
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.43",
      },
    );
    var crptext = json.decode(jsEncResult)["data"]["room$roomId"].toString();

    if (showTime != null && showTime.isNotEmpty) {
      try {
        int startTimeStamp = int.parse(showTime);
        int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        int durationInSeconds = currentTimeStamp - startTimeStamp;

        int hours = durationInSeconds ~/ 3600;
        int minutes = (durationInSeconds % 3600) ~/ 60;
        int seconds = durationInSeconds % 60;

        String formattedDuration =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
        print('斗鱼直播间 $roomId 开播时长: $formattedDuration');
      } catch (e) {
        print('计算开播时长出错: $e');
      }
    }

    return LiveRoomDetail(
      cover: roomInfo["room_pic"].toString(),
      online: int.tryParse(roomInfo["room_biz_all"]["hot"].toString()) ?? 0,
      roomId: roomInfo["room_id"].toString(),
      title: roomInfo["room_name"].toString(),
      userName: roomInfo["owner_name"].toString(),
      userAvatar: roomInfo["owner_avatar"].toString(),
      introduction: roomInfo["show_details"].toString(),
      notice: "",
      status: roomInfo["show_status"] == 1 && roomInfo["videoLoop"] != 1,
      danmakuData: roomInfo["room_id"].toString(),
      data: DouyuSign.getSign(crptext, roomInfo["room_id"].toString()),
      url: "https://www.douyu.com/$roomId",
      isRecord: roomInfo["videoLoop"] == 1,
      showTime: showTime,
    );
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    var did = generateRandomString(32);
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/search/api/searchShow",
      queryParameters: {"kw": keyword, "page": page, "pageSize": 20},
      header: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.51',
        'referer': 'https://www.douyu.com/search/',
        'Cookie': 'dy_did=$did;acf_did=$did',
      },
    );
    if (result['error'] != 0) {
      throw Exception(result['msg']);
    }
    var items = <LiveRoomItem>[];
    for (var item in result["data"]["relateShow"]) {
      var roomItem = LiveRoomItem(
        roomId: item["rid"].toString(),
        title: item["roomName"].toString(),
        cover: item["roomSrc"].toString(),
        userName: item["nickName"].toString(),
        online: parseHotNum(item["hot"].toString()),
      );
      items.add(roomItem);
    }
    var hasMore = result["data"]["relateShow"].isNotEmpty;
    return LiveSearchRoomResult(hasMore: hasMore, items: items);
  }

  Future<Map> _getRoomInfo(String roomId) async {
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/betard/$roomId",
      queryParameters: {},
      header: {
        'referer': 'https://www.douyu.com/$roomId',
        'user-agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.43',
      },
    );
    Map roomInfo;
    if (result is String) {
      roomInfo = json.decode(result)["room"];
    } else {
      roomInfo = result["room"];
    }
    return roomInfo;
  }

  //生成指定长度的16进制随机字符串
  String generateRandomString(int length) {
    var random = Random.secure();
    var values = List<int>.generate(length, (i) => random.nextInt(16));
    StringBuffer stringBuffer = StringBuffer();
    for (var item in values) {
      stringBuffer.write(item.toRadixString(16));
    }
    return stringBuffer.toString();
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    var did = generateRandomString(32);
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/search/api/searchUser",
      queryParameters: {
        "kw": keyword,
        "page": page,
        "pageSize": 20,
        "filterType": 1,
      },
      header: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.51',
        'referer': 'https://www.douyu.com/search/',
        'Cookie': 'dy_did=$did;acf_did=$did',
      },
    );

    var items = <LiveAnchorItem>[];
    for (var item in result["data"]["relateUser"]) {
      var liveStatus =
          (int.tryParse(item["anchorInfo"]["isLive"].toString()) ?? 0) == 1;
      var roomType =
          (int.tryParse(item["anchorInfo"]["roomType"].toString()) ?? 0);
      var roomItem = LiveAnchorItem(
        roomId: item["anchorInfo"]["rid"].toString(),
        avatar: item["anchorInfo"]["avatar"].toString(),
        userName: item["anchorInfo"]["nickName"].toString(),
        liveStatus: liveStatus && roomType == 0,
      );
      items.add(roomItem);
    }
    var hasMore = result["data"]["relateUser"].isNotEmpty;
    return LiveSearchAnchorResult(hasMore: hasMore, items: items);
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    var roomInfo = await _getRoomInfo(roomId);
    return roomInfo["show_status"] == 1 && roomInfo["videoLoop"] != 1;
  }

  int parseHotNum(String hn) {
    try {
      var num = double.parse(hn.replaceAll("万", ""));
      if (hn.contains("万")) {
        num *= 10000;
      }
      return num.round();
    } catch (_) {
      return -999;
    }
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
  }) {
    //尚不支持
    return Future.value([]);
  }

  @override
  bool get supportReplay => true;

  static const String _kReplayUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.51";

  /// 房间号 -> 主播的 hash 形式 up_id。
  ///
  /// 斗鱼回放接口只接受 hash 形式的 up_id（如 XrZwYgYJaAbK），
  /// betard 里的 owner_uid 是纯数字，用它会返回空列表。
  /// 搜索接口的 homeUrl（douyuapp://userHomePage?id=<hash>）带有该值。
  Future<String?> getReplayUpId(String roomId) async {
    var did = generateRandomString(32);
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/search/api/searchUser",
      queryParameters: {
        "kw": roomId,
        "page": 1,
        "pageSize": 10,
      },
      header: {
        'User-Agent': _kReplayUserAgent,
        'referer': 'https://www.douyu.com/search/',
        'Cookie': 'dy_did=$did;acf_did=$did',
      },
    );

    if (result["error"] != 0) {
      throw Exception(result["msg"]);
    }

    // 搜索结果是模糊匹配，必须按 rid 精确匹配，否则会拿到无关主播
    for (var item in (result["data"]?["relateUser"] ?? [])) {
      var anchor = item["anchorInfo"];
      if (anchor == null) {
        continue;
      }
      if (anchor["rid"]?.toString() != roomId) {
        continue;
      }
      var homeUrl = anchor["homeUrl"]?.toString() ?? "";
      return RegExp(r'id=([A-Za-z0-9]+)').firstMatch(homeUrl)?.group(1);
    }
    return null;
  }

  @override
  Future<LiveReplayListResult> getReplayList({
    required String roomId,
    int page = 1,
  }) async {
    var upId = await getReplayUpId(roomId);
    if (upId == null) {
      // 搜不到主播（房间不存在/已注销）时视为无回放
      return LiveReplayListResult(count: 0, items: []);
    }

    var result = await HttpClient.instance.getJson(
      "https://v.douyu.com/wgapi/vod/center/authorShowVideoList",
      queryParameters: {
        "up_id": upId,
        "page": page,
        "limit": 20,
      },
      header: {
        'user-agent': _kReplayUserAgent,
        'referer': 'https://v.douyu.com/',
      },
    );

    if (result["error"] != 0) {
      throw Exception(result["msg"]);
    }

    var data = result["data"] ?? {};
    var items = <LiveReplaySession>[];
    for (var session in (data["list"] ?? [])) {
      var videos = <LiveReplayItem>[];
      for (var v in (session["video_list"] ?? [])) {
        videos.add(LiveReplayItem(
          hashId: v["hash_id"]?.toString() ?? "",
          title: v["title"]?.toString() ?? "",
          cover: v["video_pic"]?.toString() ?? "",
          duration: int.tryParse(v["video_duration"]?.toString() ?? "") ?? 0,
          strDuration: v["video_str_duration"]?.toString() ?? "",
          startTime: int.tryParse(v["start_time"]?.toString() ?? "") ?? 0,
          viewNum: int.tryParse(v["view_num"]?.toString() ?? "") ?? 0,
          pointId: int.tryParse(v["point_id"]?.toString() ?? "") ?? 0,
        ));
      }
      items.add(LiveReplaySession(
        showId: int.tryParse(session["show_id"]?.toString() ?? "") ?? 0,
        title: session["title"]?.toString() ?? "",
        time: session["time"]?.toString() ?? "",
        dateFormat: session["date_format"]?.toString() ?? "",
        timeFormat: session["time_format"]?.toString() ?? "",
        items: videos,
      ));
    }

    return LiveReplayListResult(
      count: int.tryParse(data["count"]?.toString() ?? "") ?? 0,
      items: items,
    );
  }

  @override
  Future<LiveReplayUrl> getReplayUrl({
    required String roomId,
    required String hashId,
  }) async {
    var html = await HttpClient.instance.getText(
      "https://v.douyu.com/show/$hashId",
      queryParameters: {},
      header: {'user-agent': _kReplayUserAgent},
    );

    var room = _parseReplayPageData(html);
    if (room == null) {
      throw Exception("无法解析回放页面");
    }

    var vid = room["vid"]?.toString() ?? "";
    var pointId = room["point_id"]?.toString() ?? "";

    // 回放页的签名函数与直播间相同（ub98484234），复用 DouyuSign。
    // 注意：需要传入含该函数的 <script> 内容，而不是整页 HTML。
    var script = _extractSignScript(html);
    if (script == null) {
      throw Exception("无法解析回放签名脚本");
    }
    var sign = DouyuSign.getSign(script, pointId);

    var result = await HttpClient.instance.postJson(
      "https://v.douyu.com/wgapi/vodnc/front/stream/getStreamUrlWeb",
      data: "$sign&vid=$vid",
      header: {
        'user-agent': _kReplayUserAgent,
        'referer': 'https://v.douyu.com/show/$hashId',
      },
      formUrlEncoded: true,
    );

    if (result["error"] != 0) {
      throw Exception(result["msg"]);
    }

    // thumb_video 是 JSON 对象，键顺序由服务端决定（实测出现过
    // normal 在前、super 在前的多种排列），不能当作清晰度高低。
    // 各档位自带 level（标清 5 / 高清 10 / 1080P 15 / 原画 20），
    // 按 level 降序排列后，索引 0 才是真正的最高清晰度。
    var qualities = <LiveReplayQuality>[];
    var levels = <int>[];
    var thumbVideo = result["data"]?["thumb_video"];
    if (thumbVideo is Map) {
      for (var key in thumbVideo.keys) {
        var item = thumbVideo[key];
        var url = item["url"]?.toString() ?? "";
        if (url.isEmpty) {
          continue;
        }
        qualities.add(LiveReplayQuality(
          quality: key.toString(),
          name: item["name"]?.toString() ?? key.toString(),
          url: url,
        ));
        levels.add(int.tryParse(item["level"]?.toString() ?? "") ?? 0);
      }
    }

    var order = List<int>.generate(qualities.length, (i) => i)
      ..sort((a, b) => levels[b].compareTo(levels[a]));
    return LiveReplayUrl(
      qualities: order.map((i) => qualities[i]).toList(),
    );
  }

  /// 从回放页提取 window.$DATA 中的 ROOM 节点。
  ///
  /// $DATA 是 JS 对象字面量（键无引号），需要先转成合法 JSON。
  Map? _parseReplayPageData(String html) {
    var match = RegExp(r'window\.\$DATA\s*=\s*(\{.*?\});', dotAll: true)
        .firstMatch(html);
    if (match == null) {
      return null;
    }
    var jsonText = match.group(1)!.replaceAllMapped(
          RegExp(r'([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:'),
          (m) => '${m[1]}"${m[2]}":',
        );
    try {
      var data = jsonDecode(jsonText);
      if (data is Map) {
        var room = data["ROOM"];
        return room is Map ? room : null;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// 提取含 ub98484234 签名函数的 <script> 内容
  String? _extractSignScript(String html) {
    for (var m
        in RegExp(r'<script[^>]*>(.*?)</script>', dotAll: true).allMatches(html)) {
      var content = m.group(1) ?? "";
      if (content.contains("ub98484234")) {
        return content;
      }
    }
    return null;
  }
}

class DouyuPlayData {
  final int rate;
  final List<String> cdns;
  DouyuPlayData(this.rate, this.cdns);
}
