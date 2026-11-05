import 'dart:convert';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:dio/dio.dart';

/// 自己服务器（bili-feed，Tailscale 内网）上的精选推荐，以及使用记录上传。
abstract final class PicksHttp {
  static const server = 'http://100.80.206.107:8790';

  // 不用 Request().dio：那边的拦截器会给请求加 B 站的 cookie 和请求头
  static final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(minutes: 5),
    ),
  );

  static Map<String, dynamic> _json(Object? data) =>
      (data is String ? jsonDecode(data) : data) as Map<String, dynamic>;

  static Future<LoadingState<List<HotVideoItemModel>>> list({
    required int pn,
  }) async {
    try {
      final res = await _dio.get(
        '$server/picks',
        queryParameters: {'page': pn},
      );
      final data = _json(res.data);
      if (data['code'] == 0) {
        return Success(
          (data['data']['list'] as List)
              .map((e) => HotVideoItemModel.fromJson(e))
              .toList(),
        );
      }
      return Error(data['message']?.toString() ?? '精选服务器返回 ${data['code']}');
    } catch (e) {
      return Error('连不上精选服务器（需要打开 Tailscale）\n$e');
    }
  }

  /// 上传使用记录数据库（VACUUM INTO 得到的完整副本）。成功返回 true。
  static Future<bool> uploadUsageLog(List<int> bytes) async {
    try {
      final res = await _dio.post(
        '$server/usage_log',
        data: Stream.fromIterable([bytes]),
        options: Options(
          contentType: 'application/octet-stream',
          headers: {Headers.contentLengthHeader: bytes.length},
        ),
      );
      return _json(res.data)['code'] == 0;
    } catch (_) {
      return false;
    }
  }
}
