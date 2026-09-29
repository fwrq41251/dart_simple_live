import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/replay/replay_list_controller.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/page_list_view.dart';

/// 回放列表页
class ReplayListPage extends GetView<ReplayListController> {
  const ReplayListPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Obx(
          () => Text(
            controller.replayCount.value > 0
                ? "回放 (${controller.replayCount.value})"
                : "回放",
          ),
        ),
      ),
      body: PageListView(
        pageController: controller,
        padding: AppStyle.edgeInsetsA12,
        separatorBuilder: (_, __) => AppStyle.vGap12,
        itemBuilder: (_, i) {
          var session = controller.list[i];
          return _buildSessionCard(context, session);
        },
      ),
    );
  }

  Widget _buildSessionCard(BuildContext context, dynamic session) {
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: AppStyle.edgeInsetsA12,
            child: Row(
              children: [
                const Icon(Remix.history_line, size: 18),
                AppStyle.hGap8,
                Expanded(
                  child: Text(
                    session.time as String,
                    style: Get.textTheme.titleSmall,
                  ),
                ),
                Text(
                  session.dateFormat as String,
                  style: Get.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          // 该场次下的分段
          ...(session.items as List).map<Widget>((item) {
            return ListTile(
              leading: item.cover.toString().isEmpty
                  ? const Icon(Remix.play_circle_line, size: 40)
                  : NetImage(
                      item.cover.toString(),
                      width: 64,
                      height: 40,
                      cacheWidth: 128,
                      fit: BoxFit.cover,
                    ),
              title: Text(
                item.title.toString(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                item.strDuration.toString().isEmpty
                    ? item.duration.toString()
                    : item.strDuration.toString(),
              ),
              trailing: const Icon(Remix.play_fill),
              onTap: () {
                AppNavigator.toReplayDetail(
                  site: controller.site,
                  roomId: controller.roomId,
                  item: item,
                );
              },
            );
          }).toList(),
        ],
      ),
    );
  }
}
