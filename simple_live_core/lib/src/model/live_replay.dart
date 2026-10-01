import 'dart:convert';

/// 回放场次（一次直播的完整录像，可能被切成多段）
class LiveReplaySession {
  /// 场次ID
  final int showId;

  /// 场次标题
  final String title;

  /// 场次时间描述，如 "2026-09-28 17点场"
  final String time;

  /// 相对日期，如 "昨天"
  final String dateFormat;

  /// 时间，如 "17:55"
  final String timeFormat;

  /// 该场次下的录像分段
  final List<LiveReplayItem> items;

  LiveReplaySession({
    required this.showId,
    required this.title,
    required this.time,
    required this.dateFormat,
    required this.timeFormat,
    required this.items,
  });

  @override
  String toString() => json.encode({
    "showId": showId,
    "title": title,
    "time": time,
    "dateFormat": dateFormat,
    "timeFormat": timeFormat,
    "items": items.map((e) => e.toString()).toList(),
  });
}

/// 回放分段（单个可播放的录像）
class LiveReplayItem {
  /// 回放标识，用于请求详情与播放地址
  final String hashId;

  /// 标题
  final String title;

  /// 封面
  final String cover;

  /// 时长（秒）
  final int duration;

  /// 时长字符串，如 "01:23:45"
  final String strDuration;

  /// 开始时间（秒级时间戳）
  final int startTime;

  /// 观看数
  final int viewNum;

  /// 分P标识
  final int pointId;

  LiveReplayItem({
    required this.hashId,
    required this.title,
    required this.cover,
    required this.duration,
    required this.strDuration,
    required this.startTime,
    required this.viewNum,
    required this.pointId,
  });

  @override
  String toString() => json.encode({
    "hashId": hashId,
    "title": title,
    "cover": cover,
    "duration": duration,
    "strDuration": strDuration,
    "startTime": startTime,
    "viewNum": viewNum,
    "pointId": pointId,
  });
}

/// 回放列表结果
class LiveReplayListResult {
  /// 总场次数
  final int count;

  /// 场次列表
  final List<LiveReplaySession> items;

  LiveReplayListResult({required this.count, required this.items});
}

/// 回放的单个清晰度及其播放地址
class LiveReplayQuality {
  /// 清晰度标识，如 "normal"、"high"、"1080p60"
  final String quality;

  /// 清晰度名称，如 "标清480P"
  final String name;

  /// 播放地址
  final String url;

  LiveReplayQuality({
    required this.quality,
    required this.name,
    required this.url,
  });

  @override
  String toString() =>
      json.encode({"quality": quality, "name": name, "url": url});
}

/// 回放的播放地址集合（含请求头）
class LiveReplayUrl {
  /// 可用清晰度
  final List<LiveReplayQuality> qualities;

  /// 请求头
  final Map<String, String>? headers;

  LiveReplayUrl({required this.qualities, this.headers});
}

/// 一条与回放时间轴绑定的弹幕。
class LiveReplayDanmaku {
  /// 相对当前回放分段起点的时间（毫秒）。
  final int time;

  final String text;

  /// ARGB 颜色值。
  final int color;

  LiveReplayDanmaku({
    required this.time,
    required this.text,
    required this.color,
  });
}

/// 回放弹幕的一个按需加载区间。
class LiveReplayDanmakuResult {
  final int startTime;

  /// 本次响应覆盖到的时间（毫秒）；-1 表示已覆盖到回放结束。
  final int endTime;

  final List<LiveReplayDanmaku> items;

  LiveReplayDanmakuResult({
    required this.startTime,
    required this.endTime,
    required this.items,
  });
}
