import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/picks.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';

/// 首页「精选」：bili-feed 按评价模型从游客首页里挑的视频。服务器每次给下一组还没发过的，
/// 所以下拉刷新换一组新的，上滑接着加载；服务器上的序列用完才到底。
class PicksController
    extends CommonListController<List<HotVideoItemModel>, HotVideoItemModel> {
  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  Future<LoadingState<List<HotVideoItemModel>>> customGetData() =>
      PicksHttp.list(pn: page);
}
