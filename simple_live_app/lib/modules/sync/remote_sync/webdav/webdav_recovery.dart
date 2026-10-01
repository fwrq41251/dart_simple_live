import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';

class WebDavRecoverySelection {
  const WebDavRecoverySelection({
    required this.follows,
    required this.histories,
    required this.blockedWords,
    required this.bilibiliAccount,
  });

  final bool follows;
  final bool histories;
  final bool blockedWords;
  final bool bilibiliAccount;
}

class WebDavRecoveryPlan {
  WebDavRecoveryPlan({
    this.follows,
    this.tags,
    this.histories,
    this.blockedWords,
    this.bilibiliCookie,
    this.settings,
  });

  final List<FollowUser>? follows;
  final List<FollowUserTag>? tags;
  final List<History>? histories;
  final List<String>? blockedWords;
  final String? bilibiliCookie;
  final Map<dynamic, dynamic>? settings;
}

class WebDavRecoveryParser {
  static const followsName = 'SimpleLive_follows.json';
  static const historiesName = 'SimpleLive_histories.json';
  static const blockedWordsName = 'SimpleLive_blocked_word.json';
  static const bilibiliAccountName = 'SimpleLive_bilibili_account.json';
  static const settingsName = 'SimpleLive_Settings.json';
  static const tagsName = 'SimpleLive_Tags.json';

  WebDavRecoveryPlan parse(
    List<int> bytes,
    WebDavRecoverySelection selection,
  ) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final dataByName = <String, dynamic>{};
    final selectedNames = <String>{
      settingsName,
      if (selection.follows) ...[followsName, tagsName],
      if (selection.histories) historiesName,
      if (selection.blockedWords) blockedWordsName,
      if (selection.bilibiliAccount) bilibiliAccountName,
    };

    for (final file in archive) {
      if (!file.isFile || !selectedNames.contains(file.name)) continue;
      if (dataByName.containsKey(file.name)) {
        throw const FormatException('备份中包含重复文件');
      }
      final decoded = jsonDecode(utf8.decode(file.content as List<int>));
      if (decoded is! Map<String, dynamic> || !decoded.containsKey('data')) {
        throw FormatException('${file.name} 缺少 data');
      }
      dataByName[file.name] = decoded['data'];
    }
    final missingNames = selectedNames.difference(dataByName.keys.toSet());
    if (missingNames.isNotEmpty) {
      throw FormatException('备份缺少文件: ${missingNames.join(', ')}');
    }

    return WebDavRecoveryPlan(
      follows: selection.follows
          ? _models(dataByName[followsName], followsName, FollowUser.fromJson)
          : null,
      tags: selection.follows ? _tags(dataByName[tagsName]) : null,
      histories: selection.histories
          ? _models(dataByName[historiesName], historiesName, History.fromJson)
          : null,
      blockedWords: selection.blockedWords
          ? _strings(dataByName[blockedWordsName], blockedWordsName)
          : null,
      bilibiliCookie: selection.bilibiliAccount
          ? _cookie(dataByName[bilibiliAccountName])
          : null,
      settings: _map(dataByName[settingsName], settingsName),
    );
  }

  List<T>? _models<T>(
      dynamic value, String name, T Function(Map<String, dynamic>) fromJson) {
    if (value == null) return null;
    if (value is! List) throw FormatException('$name 的 data 不是列表');
    return value.map((item) {
      if (item is! Map) throw FormatException('$name 包含非法记录');
      return fromJson(Map<String, dynamic>.from(item));
    }).toList();
  }

  List<FollowUserTag>? _tags(dynamic value) {
    final tags = _models(value, tagsName, FollowUserTag.fromJson);
    if (tags == null) return null;
    for (var index = 0; index < tags.length; index++) {
      tags[index].order ??= index;
    }
    return tags;
  }

  List<String>? _strings(dynamic value, String name) {
    if (value == null) return null;
    if (value is! List || value.any((item) => item is! String)) {
      throw FormatException('$name 包含非法记录');
    }
    return value.cast<String>().map((word) => word.trim()).toList();
  }

  String? _cookie(dynamic value) {
    if (value == null) return null;
    if (value is! Map || value['cookie'] is! String) {
      throw const FormatException('哔哩哔哩账号数据无效');
    }
    return value['cookie'] as String;
  }

  Map<dynamic, dynamic>? _map(dynamic value, String name) {
    if (value == null) return null;
    if (value is! Map) throw FormatException('$name 的 data 不是对象');
    return Map<dynamic, dynamic>.from(value);
  }
}

class RecoveryCommitStep {
  const RecoveryCommitStep({required this.apply, required this.rollback});

  final Future<void> Function() apply;
  final Future<void> Function() rollback;
}

Future<void> commitRecovery(List<RecoveryCommitStep> steps) async {
  var attempted = -1;
  try {
    for (var index = 0; index < steps.length; index++) {
      attempted = index;
      await steps[index].apply();
    }
  } catch (error, stackTrace) {
    Object? rollbackError;
    for (var index = attempted; index >= 0; index--) {
      try {
        await steps[index].rollback();
      } catch (error) {
        rollbackError ??= error;
      }
    }
    if (rollbackError != null) {
      throw StateError('恢复写入失败，且回滚未完全成功: $error; $rollbackError');
    }
    Error.throwWithStackTrace(error, stackTrace);
  }
}
