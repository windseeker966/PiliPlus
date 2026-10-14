// 稍后再看模式：刷照常，看要排队。
//
// 开启后（默认开启），在推荐、搜索、动态、相关视频等地方点开视频不会直接播放，而是先加入稍后再看；
// 加入满 [LaterMode.cooldown] 后才能从稍后再看里播放。每天最多加入 [LaterMode.dailyAddQuota] 个，
// 另有 [LaterMode.dailyInstantQuota] 次「立即观看」。下载、历史记录、私信和外部分享打开的视频直接播放。
// 视频页内的自动连播只会接着播稍后再看列表里已冷却的视频；看完的视频从稍后再看移除。
//
// 记录的事件（写入 UsageLog）：
//   later_add            加入稍后再看，带 route（加入时所在页面）
//   later_play           从稍后再看播放，带 waited_min（加入后等了多久，未知时不带）
//   later_cooldown_block 想看还在冷却的视频，带 wait_min、auto（是否为自动连播）
//   later_quota_block    额度用完时想加入新视频
//   instant_play         用了一次立即观看，带 reason（new / cooldown / pgc）
//   later_direct_play    不经过稍后再看直接播放，带 via（download / history / message / external）
//   later_auto_remove    看完后自动从稍后再看移除
//   later_mode_on / later_mode_off  开关稍后再看模式
//   later_sync           启动时同步稍后再看列表，带 result（ok / partial / error / not_login）

import 'dart:async';

import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/models_new/later/list.dart';
import 'package:PiliPlus/services/usage_log.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 不经过稍后再看、直接播放的入口。
enum LaterPlaySource { download, history, message }

abstract final class LaterMode {
  static const cooldown = Duration(minutes: 30);
  static const dailyAddQuota = 8;
  static const dailyInstantQuota = 3;

  /// 关闭模式前需要等待的秒数。
  static const offDelaySeconds = 60;

  /// 外部链接拉起后，这段时间内打开的视频算作外部分享。
  static const _externalWindow = Duration(seconds: 15);

  /// 本地记下的加入时间保留多久；启动时完整拉取一遍列表后会以服务器为准。
  static const _rememberFor = Duration(days: 3);
  static const _maxStartupPages = 10;

  static const _keyAddedAt = 'laterModeAddedAt';
  static const _keyDay = 'laterModeDay';
  static const _keyAdds = 'laterModeAdds';
  static const _keyInstant = 'laterModeInstant';

  static bool get enabled =>
      GStorage.setting.get(SettingBoxKey.laterMode, defaultValue: true);

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  static void _log(String type, Map<String, Object?> fields) =>
      UsageLog.log(type, fields);

  // ---- 稍后再看列表与加入时间 ----

  /// bvid → 加入时间（毫秒）；0 表示在列表里但不知道加入时间，视为已冷却。
  static Map<String, int>? _addedAtCache;

  static Map<String, int> get _addedAt {
    if (_addedAtCache case final cache?) return cache;
    final raw = GStorage.localCache.get(_keyAddedAt);
    final map = <String, int>{};
    if (raw is Map) {
      raw.forEach((key, value) {
        if (key is String && value is int) map[key] = value;
      });
    }
    return _addedAtCache = map;
  }

  static void _saveAddedAt() {
    final minMs = _now() - _rememberFor.inMilliseconds;
    // 不知道加入时间（0）的是服务器列表里的视频，由启动时的完整拉取维护，这里不清理。
    _addedAt.removeWhere((_, at) => at != 0 && at < minMs);
    GStorage.localCache.put(_keyAddedAt, Map<String, int>.of(_addedAt));
  }

  static String? _bvidOf({String? bvid, Object? aid}) {
    if (bvid != null) return bvid;
    final id = aid is int ? aid : int.tryParse('$aid');
    return id == null ? null : IdUtils.av2bv(id);
  }

  static int _addedAtOf(LaterItemModel item) {
    final addAt = item.addAt;
    return addAt == null || addAt <= 0 ? 0 : addAt * 1000;
  }

  /// 稍后再看列表接口返回后调用，记下每个视频的加入时间。
  static void rememberList(List<LaterItemModel>? list) {
    if (list == null || list.isEmpty) return;
    for (final item in list) {
      final bvid = _bvidOf(bvid: item.bvid, aid: item.aid);
      if (bvid == null) continue;
      final serverAt = _addedAtOf(item);
      // 服务器没给加入时间时，保留本地记的时间。
      if (serverAt != 0 || !_addedAt.containsKey(bvid)) {
        _addedAt[bvid] = serverAt;
      }
    }
    _saveAddedAt();
  }

  /// 启动时拉取整个稍后再看列表，以服务器为准刷新本地记录。
  static Future<void> init() async {
    if (!enabled) return;
    if (!Accounts.main.isLogin) {
      _log('later_sync', const {'result': 'not_login'});
      return;
    }
    try {
      await _syncList();
    } catch (e) {
      // 网络等错误：保留本地记录，下次再同步。
      _log('later_sync', {'result': 'error', 'error': '$e'});
    }
  }

  static Future<void> _syncList() async {
    final fetched = <String, int>{};
    for (var page = 1; page <= _maxStartupPages; page++) {
      final res = await UserHttp.seeYouLater(page: page);
      final data = res.dataOrNull;
      if (data == null) {
        // 请求失败，保留本地记录。
        _log('later_sync', {'result': 'error', 'error': '$res'});
        return;
      }
      final list = data.list ?? const <LaterItemModel>[];
      for (final item in list) {
        final bvid = _bvidOf(bvid: item.bvid, aid: item.aid);
        if (bvid != null) fetched[bvid] = _addedAtOf(item);
      }
      if (list.length < 20 || fetched.length >= (data.count ?? 0)) {
        // 拿到了完整列表：不在列表里的视频已被移除。刚加入、列表可能还没更新的保留。
        final recentMs = _now() - cooldown.inMilliseconds;
        _addedAt.removeWhere(
          (bvid, at) => !fetched.containsKey(bvid) && at < recentMs,
        );
        fetched.forEach((bvid, at) {
          if (at != 0 || !_addedAt.containsKey(bvid)) _addedAt[bvid] = at;
        });
        _saveAddedAt();
        _log('later_sync', {'result': 'ok', 'items': fetched.length});
        return;
      }
    }
    _log('later_sync', {'result': 'partial', 'items': fetched.length});
  }

  // ---- 每日额度 ----

  static String _today() {
    final d = DateTime.now();
    return '${d.year}-${d.month}-${d.day}';
  }

  static int _count(String key) {
    final box = GStorage.localCache;
    if (box.get(_keyDay) != _today()) return 0;
    return box.get(key, defaultValue: 0) as int;
  }

  static void _increment(String key) {
    final box = GStorage.localCache;
    if (box.get(_keyDay) != _today()) {
      box.putAll({_keyDay: _today(), _keyAdds: 0, _keyInstant: 0});
    }
    box.put(key, _count(key) + 1);
  }

  static int get addsLeft =>
      (dailyAddQuota - _count(_keyAdds)).clamp(0, dailyAddQuota);

  static int get instantLeft =>
      (dailyInstantQuota - _count(_keyInstant)).clamp(0, dailyInstantQuota);

  // ---- 加入与移除（由 UserHttp 调用） ----

  /// 加入稍后再看之前调用；额度用完时返回 false 并提示。
  static bool beforeAdd() {
    if (!enabled || addsLeft > 0) return true;
    _log('later_quota_block', const {});
    SmartDialog.showToast('今天的 $dailyAddQuota 个额度用完了，去看稍后再看里已经挑好的视频吧');
    return false;
  }

  /// 成功加入稍后再看后调用，返回要显示的提示。
  static String onAdded({String? bvid, Object? aid}) {
    if (!enabled) return 'yeah！稍后再看';
    final id = _bvidOf(bvid: bvid, aid: aid);
    if (id != null) {
      _addedAt[id] = _now();
      _saveAddedAt();
    }
    _increment(_keyAdds);
    _log('later_add', {'bvid': id, 'route': Get.currentRoute});
    final left = addsLeft;
    return '已加入稍后再看，${cooldown.inMinutes} 分钟后可以看'
        '${left > 0 ? '（今天还能加 $left 个）' : '（今天的额度用完了）'}';
  }

  /// 从稍后再看移除后调用。
  static void onRemoved(Iterable<String> bvids) {
    var changed = false;
    for (final bvid in bvids) {
      changed |= _addedAt.remove(bvid) != null;
    }
    if (changed) _saveAddedAt();
  }

  /// 视频播放完成。是稍后再看里的视频时，从稍后再看移除。
  static Future<void> onCompleted({
    required String bvid,
    required int aid,
  }) async {
    if (!enabled || !_addedAt.containsKey(bvid)) return;
    final res = await UserHttp.toViewDel(aids: '$aid');
    if (res.isSuccess) {
      onRemoved([bvid]);
      _log('later_auto_remove', {'bvid': bvid});
      SmartDialog.showToast('看完了，已从稍后再看移除');
    }
  }

  // ---- 播放前的判断 ----

  static int _externalAtMs = 0;

  /// 通过外部链接拉起（分享链接、浏览器跳转等）。
  static void markExternal() => _externalAtMs = _now();

  /// 打开或切换到一个视频之前调用，返回是否可以播放。
  ///
  /// [fromLaterList] 从稍后再看列表打开；[isPgc] 番剧、课程等不能加入稍后再看的视频；
  /// [source] 直接播放的入口；[auto] 自动连播，不能播放时直接停下，不弹窗。
  static Future<bool> allowPlay({
    required String bvid,
    String? title,
    bool fromLaterList = false,
    bool isPgc = false,
    LaterPlaySource? source,
    bool auto = false,
  }) async {
    if (!enabled) return true;
    if (source != null) {
      _log('later_direct_play', {'bvid': bvid, 'via': source.name});
      return true;
    }
    if (_now() - _externalAtMs < _externalWindow.inMilliseconds) {
      _externalAtMs = 0;
      _log('later_direct_play', {'bvid': bvid, 'via': 'external'});
      return true;
    }
    if (isPgc) {
      if (auto) return false;
      return _askInstant(
        title: title,
        bvid: bvid,
        reason: 'pgc',
        message: '番剧、课程不能加入稍后再看。',
      );
    }
    final addedAt = _addedAt[bvid];
    if (addedAt != null || fromLaterList) {
      final waitMs = (addedAt ?? 0) + cooldown.inMilliseconds - _now();
      if (waitMs <= 0) {
        _log('later_play', {
          'bvid': bvid,
          if (addedAt != null && addedAt > 0)
            'waited_min': (_now() - addedAt) ~/ 60000,
        });
        return true;
      }
      final waitMin = (waitMs / 60000).ceil();
      _log('later_cooldown_block', {
        'bvid': bvid,
        'wait_min': waitMin,
        'auto': auto,
      });
      if (auto) {
        SmartDialog.showToast('下一个视频还在冷却，停止连播');
        return false;
      }
      return _askInstant(
        title: title,
        bvid: bvid,
        reason: 'cooldown',
        message: '这个视频还在冷却，$waitMin 分钟后可以看。',
      );
    }
    if (auto) return false;
    return _askAdd(title: title, bvid: bvid);
  }

  static Future<bool> _askAdd({String? title, required String bvid}) async {
    final context = Get.context;
    if (context == null) return false;
    final left = addsLeft;
    final instant = instantLeft;
    if (left <= 0) _log('later_quota_block', {'bvid': bvid});
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('稍后再看模式'),
        content: Text(
          [
            if (title != null && title.isNotEmpty) '「$title」',
            left > 0
                ? '先加入稍后再看，${cooldown.inMinutes} 分钟后可以看。今天还能加 $left 个。'
                : '今天的 $dailyAddQuota 个额度用完了，去看稍后再看里已经挑好的视频吧。',
          ].join('\n\n'),
        ),
        actions: [
          if (instant > 0)
            TextButton(
              onPressed: () => Navigator.of(context).pop('instant'),
              child: Text('立即观看（今天还剩 $instant 次）'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          if (left > 0)
            TextButton(
              onPressed: () => Navigator.of(context).pop('add'),
              child: const Text('加入稍后再看'),
            ),
        ],
      ),
    );
    switch (choice) {
      case 'add':
        await UserHttp.toViewLater(bvid: bvid);
        return false;
      case 'instant':
        _useInstant(bvid, 'new');
        return true;
      default:
        return false;
    }
  }

  static Future<bool> _askInstant({
    String? title,
    required String bvid,
    required String reason,
    required String message,
  }) async {
    final context = Get.context;
    if (context == null) return false;
    final instant = instantLeft;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('稍后再看模式'),
        content: Text(
          [
            if (title != null && title.isNotEmpty) '「$title」',
            message,
            if (instant <= 0) '今天的立即观看次数用完了。',
          ].join('\n\n'),
        ),
        actions: [
          if (instant > 0)
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('立即观看（今天还剩 $instant 次）'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('好'),
          ),
        ],
      ),
    );
    if (ok == true) {
      _useInstant(bvid, reason);
      return true;
    }
    return false;
  }

  static void _useInstant(String bvid, String reason) {
    _increment(_keyInstant);
    _log('instant_play', {'bvid': bvid, 'reason': reason});
  }

  // ---- 开关 ----

  static String get settingSubtitle => enabled
      ? '已开启：点开视频先加入稍后再看，${cooldown.inMinutes} 分钟后才能看；'
            '今天还能加 $addsLeft 个，立即观看还剩 $instantLeft 次'
      : '已关闭';

  /// 设置页点击：开启立即生效；关闭需要等待 [offDelaySeconds] 秒并会被记录。
  static Future<void> toggle(
    BuildContext context,
    VoidCallback setState,
  ) async {
    if (!enabled) {
      await GStorage.setting.put(SettingBoxKey.laterMode, true);
      _log('later_mode_on', const {});
      setState();
      unawaited(init());
      return;
    }
    var remaining = offDelaySeconds;
    Timer? timer;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          timer ??= Timer.periodic(const Duration(seconds: 1), (t) {
            remaining--;
            if (remaining <= 0) t.cancel();
            if (context.mounted) setDialogState(() {});
          });
          return AlertDialog(
            title: const Text('关闭稍后再看模式？'),
            content: const Text('关闭后点开视频会直接播放。关闭会被记录在使用记录里。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('不关了'),
              ),
              TextButton(
                onPressed: remaining > 0
                    ? null
                    : () => Navigator.of(context).pop(true),
                child: Text(remaining > 0 ? '关闭（$remaining 秒）' : '关闭'),
              ),
            ],
          );
        },
      ),
    );
    timer?.cancel();
    if (ok == true) {
      await GStorage.setting.put(SettingBoxKey.laterMode, false);
      _log('later_mode_off', const {});
      setState();
    }
  }
}
