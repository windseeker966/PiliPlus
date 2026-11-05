import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/picks.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';

/// 首页「精选」：bili-feed 按评价模型从游客首页里挑的视频，一次给一批，没有下一页。
class PicksController
    extends CommonListController<List<HotVideoItemModel>, HotVideoItemModel> {
  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  void checkIsEnd(int length) => isEnd = true;

  @override
  Future<LoadingState<List<HotVideoItemModel>>> customGetData() =>
      PicksHttp.list(pn: page);
}
