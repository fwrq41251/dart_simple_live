import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 回放列表
class ReplayListController extends BasePageController<LiveReplaySession> {
  final Site pSite;
  final String pRoomId;

  ReplayListController({required this.pSite, required this.pRoomId}) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
  }

  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  /// 该房间是否支持回放
  bool get supportReplay => site.liveSite.supportReplay;

  @override
  void onInit() {
    super.onInit();
    loadData();
  }

  @override
  Future<List<LiveReplaySession>> getData(int page, int pageSize) async {
    if (!supportReplay) {
      return [];
    }
    var result = await site.liveSite.getReplayList(
      roomId: roomId,
      page: page,
    );
    // 场次数用于展示
    replayCount.value = result.count;
    return result.items;
  }

  var replayCount = 0.obs;
}
