import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:uuid/uuid.dart';
import 'package:collection/collection.dart';

class DBService extends GetxService {
  static DBService get instance => Get.find<DBService>();
  static const int maxReplayProgressCount = 200;

  late Box<History> historyBox;
  late Box<FollowUser> followBox;
  late Box<FollowUserTag> tagBox;
  late Box replayProgressBox;
  final Uuid uuid = const Uuid();

  Future init() async {
    historyBox = await Hive.openBox("History");
    followBox = await Hive.openBox("FollowUser");
    tagBox = await Hive.openBox("FollowUserTag");
    await _migrateFollowTagKeys();
    replayProgressBox = await Hive.openBox("ReplayProgress");
  }

  Future<void> _migrateFollowTagKeys() async {
    final tagsById = <String, FollowUserTag>{};
    var needsMigration = false;

    for (final key in tagBox.keys) {
      final followTag = tagBox.get(key);
      if (followTag == null) {
        continue;
      }
      needsMigration = needsMigration ||
          key != followTag.id ||
          followTag.order == null ||
          tagsById.containsKey(followTag.id);
      if (key == followTag.id || !tagsById.containsKey(followTag.id)) {
        tagsById[followTag.id] = followTag;
      }
    }

    if (needsMigration) {
      var order = 0;
      for (final followTag in tagsById.values) {
        followTag.order = order++;
      }
      await tagBox.clear();
      await tagBox.putAll(tagsById);
    }
  }

  // follow_user_tag 相关逻辑
  bool getFollowTagExist(String id) {
    return tagBox.containsKey(id);
  }

  // 删除标签
  Future deleteFollowTag(String id) async {
    await tagBox.delete(id);
  }

  FollowUserTag? getFollowTag(String tag) {
    return tagBox.values.firstWhereOrNull((item) => item.tag == tag);
  }

  // 判断标签名称是否重复
  bool getFollowTagExistByTag(String tag) {
    return tagBox.values.any((item) => item.tag == tag);
  }

  // 获取标签列表
  List<FollowUserTag> getFollowTagList() {
    final tags = tagBox.values.toList();
    final originalOrder = {
      for (var index = 0; index < tags.length; index++) tags[index].id: index,
    };
    tags.sort((a, b) => (a.order ?? originalOrder[a.id] ?? 0)
        .compareTo(b.order ?? originalOrder[b.id] ?? 0));
    return tags;
  }

  // 修改标签
  Future updateFollowTag(FollowUserTag followTag) async {
    await tagBox.put(followTag.id, followTag);
  }

  // 添加标签
  Future<FollowUserTag> addFollowTag(String tag) async {
    // 限制标签唯一且长度不超过8个字符
    if (getFollowTagExistByTag(tag)) {
      return getFollowTag(tag)!;
    }
    if (tag.length > 8) {
      throw ArgumentError.value(tag, 'tag', '标签名称不能超过8个字符');
    }
    final String uniqueId = uuid.v4();
    final followUserTag = FollowUserTag(
      id: uniqueId,
      tag: tag,
      userId: [],
      order: tagBox.length,
    );
    await tagBox.put(uniqueId, followUserTag);
    return followUserTag;
  }

  // 调整标签顺序
  Future updateFollowTagOrder(List<FollowUserTag> userTagList) async {
    for (var i = 0; i < userTagList.length; i++) {
      userTagList[i].order = i;
    }
    final Map<String, FollowUserTag> updatedMap = {
      for (final followTag in userTagList) followTag.id: followTag,
    };
    await tagBox.clear();
    await tagBox.putAll(updatedMap);
  }

  bool getFollowExist(String id) {
    return followBox.containsKey(id);
  }

  List<FollowUser> getFollowList() {
    return followBox.values.toList();
  }

  Future addFollow(FollowUser follow) async {
    await followBox.put(follow.id, follow);
  }

  Future deleteFollow(String id) async {
    await followBox.delete(id);
  }

  History? getHistory(String id) {
    if (historyBox.containsKey(id)) {
      return historyBox.get(id);
    }
    return null;
  }

  Future addOrUpdateHistory(History history) async {
    await historyBox.put(history.id, history);
  }

  List<History> getHistores() {
    var his = historyBox.values.toList();
    his.sort((a, b) => b.updateTime.compareTo(a.updateTime));
    return his;
  }

  int? getReplayProgress(String id) {
    var value = replayProgressBox.get(id);
    if (value is! Map) {
      return null;
    }
    var position = value["position"];
    return position is int ? position : null;
  }

  Future<void> saveReplayProgress(String id, int position) async {
    await replayProgressBox.put(id, {
      "position": position,
      "updateTime": DateTime.now().millisecondsSinceEpoch,
    });
    if (replayProgressBox.length <= maxReplayProgressCount) {
      return;
    }

    var entries = replayProgressBox.toMap().entries.toList()
      ..sort((a, b) {
        var aTime = a.value is Map && a.value["updateTime"] is int
            ? a.value["updateTime"] as int
            : 0;
        var bTime = b.value is Map && b.value["updateTime"] is int
            ? b.value["updateTime"] as int
            : 0;
        return aTime.compareTo(bTime);
      });
    var expiredKeys = entries
        .take(replayProgressBox.length - maxReplayProgressCount)
        .map((e) => e.key);
    await replayProgressBox.deleteAll(expiredKeys);
  }

  Future<void> removeReplayProgress(String id) async {
    await replayProgressBox.delete(id);
  }
}
