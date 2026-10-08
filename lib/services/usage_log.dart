// 使用行为记录：把页面切换、视频观看、列表刷新等事件发给本地的「本地时间采集」应用
// （com.wind.timetracker），由它写入自己的数据库。只在 Android 上工作，
// 对方未安装或调用失败时事件暂存在内存里，之后重试，不影响 PiliPlus 本身。
//
// 事件类型：
//   app_start / app_foreground / app_background
//   page_enter / page_leave         页面（路由）进入与离开
//   nav_tab / home_tab              底部导航、首页顶部分区切换
//   list_refresh / list_load_more   列表下拉刷新（含首次加载）与上滑加载更多
//   video_info                      视频详情加载完成（标题、UP 主、时长等）
//   player_playing / player_paused / player_completed  播放状态变化
//   video_end                       一个视频的观看结束（离开、切换），附观看时长汇总

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pb.dart' show DetailItem;
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/live/live_room_info_h5/data.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/episode.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

abstract final class UsageLog {
  static const _channel = MethodChannel('piliplus/usage_log');
  static final bool _enabled = Platform.isAndroid;

  static const _flushDelay = Duration(seconds: 3);
  static const _retryDelay = Duration(seconds: 30);
  static const _flushBatchSize = 50;
  static const _maxQueue = 2000;

  static final List<Map<String, Object?>> _queue = [];
  static Timer? _flushTimer;
  static bool _flushing = false;
  static bool _unsupported = false;
  static AppLifecycleListener? _lifecycleListener;

  static final NavigatorObserver navigatorObserver = _UsageNavigatorObserver();

  /// 在 runApp 之前调用。
  static void init() {
    if (!_enabled) return;
    _lifecycleListener ??= AppLifecycleListener(
      onResume: () => log('app_foreground', const {}),
      onPause: () {
        log('app_background', _video.snapshot());
        _flushNow();
      },
    );
    log('app_start', const {});
  }

  static void log(String type, Map<String, Object?> fields) {
    if (!_enabled || _unsupported) return;
    _queue.add({
      'timestamp_ms': DateTime.now().millisecondsSinceEpoch,
      'event_type': type,
      for (final e in fields.entries)
        if (e.value != null) e.key: e.value,
    });
    if (_queue.length > _maxQueue) {
      _queue.removeRange(0, _queue.length - _maxQueue);
    }
    if (_queue.length >= _flushBatchSize) {
      _flushNow();
    } else {
      _flushTimer ??= Timer(_flushDelay, _flushNow);
    }
  }

  static void _flushNow() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _flush();
  }

  static Future<void> _flush() async {
    if (_flushing || _queue.isEmpty || _unsupported) return;
    _flushing = true;
    final batch = List.of(_queue.take(500));
    try {
      await _channel.invokeMethod<int>('send', jsonEncode(batch));
      _queue.removeRange(0, batch.length);
    } on MissingPluginException {
      _unsupported = true;
      _queue.clear();
    } catch (_) {
      // 「本地时间采集」未安装或暂不可用：保留队列，稍后重试。
      _flushTimer ??= Timer(_retryDelay, _flushNow);
    } finally {
      _flushing = false;
    }
    if (_queue.isNotEmpty && _flushTimer == null) {
      _flushTimer = Timer(_flushDelay, _flushNow);
    }
  }

  // ---- 列表 ----

  /// 列表开始请求数据：isRefresh 为下拉刷新或首次加载，否则为上滑加载更多。
  static void listQuery(Object controller, bool isRefresh, int page) {
    log(isRefresh ? 'list_refresh' : 'list_load_more', {
      'list': controller.runtimeType.toString(),
      'page': page,
    });
  }

  // ---- 视频 ----

  static final _video = _VideoTracker();

  /// 视频（或直播、番剧、离线缓存）详情加载完成。
  static void videoInfo(
    Object? data,
    int cid, {
    String? artist,
  }) {
    if (!_enabled || data == null) return;
    final info = _videoInfoFields(data, cid, artist);
    if (info == null) return;
    log('video_info', info);
    _video.onInfo(cid, info);
  }

  static void playerState(
    PlayerStatus status,
    Duration position, {
    required bool isLive,
    required double speed,
  }) {
    if (!_enabled) return;
    _video.onState(status, position, isLive: isLive, speed: speed);
  }

  static Map<String, Object?>? _videoInfoFields(
    Object data,
    int cid,
    String? artist,
  ) {
    switch (data) {
      case VideoDetailData():
        final pages = data.pages;
        final multiPage = pages != null && pages.length > 1;
        Part? part;
        if (multiPage) {
          for (final p in pages) {
            if (p.cid == cid) {
              part = p;
              break;
            }
          }
        }
        return {
          'kind': 'ugc',
          'bvid': data.bvid,
          'aid': data.aid,
          'cid': cid,
          'title': data.title,
          'owner': data.owner?.name,
          'owner_mid': data.owner?.mid,
          'duration_sec': multiPage ? part?.duration : data.duration,
          if (multiPage) ...{
            'part': part?.part,
            'part_index': part?.page,
            'part_count': pages.length,
          },
        };
      case EpisodeItem():
        return {
          'kind': data.from == 'pugv' ? 'pugv' : 'pgc',
          'bvid': data.bvid,
          'aid': data.aid,
          'cid': cid,
          'ep_id': data.epId ?? data.id,
          'title': data.showTitle ?? data.longTitle ?? data.title,
          'owner': artist,
          'duration_sec': data.duration == null
              ? null
              : data.from == 'pugv'
              ? data.duration
              : data.duration! ~/ 1000,
        };
      case RoomInfoH5Data():
        return {
          'kind': 'live',
          'room_id': cid,
          'title': data.roomInfo?.title,
          'owner': data.anchorInfo?.baseInfo?.uname,
        };
      case Part():
        return {
          'kind': 'part',
          'cid': cid,
          'title': data.part,
          'owner': artist,
          'duration_sec': data.duration,
        };
      case DetailItem(:final arc):
        return {
          'kind': 'audio',
          'cid': cid,
          'title': arc.title,
          'owner': data.owner.name,
          'duration_sec': arc.duration.toInt(),
        };
      case BiliDownloadEntryInfo():
        return {
          'kind': 'offline',
          'bvid': data.bvid,
          'aid': data.avid,
          'cid': cid,
          'title': data.showTitle,
          'owner': data.ownerName,
          'duration_sec': data.totalTimeMilli ~/ 1000,
        };
      default:
        return null;
    }
  }
}

/// 以 cid 区分「当前在看的视频」，统计每个视频实际播放的时长和看到的位置。
class _VideoTracker {
  final Map<int, Map<String, Object?>> _infoByCid = {};
  _VideoSession? _session;
  String? _lastStatus;

  void onInfo(int cid, Map<String, Object?> info) {
    _infoByCid.remove(cid);
    _infoByCid[cid] = info;
    if (_infoByCid.length > 50) _infoByCid.remove(_infoByCid.keys.first);
    final session = _session;
    if (session != null && session.cid == cid) {
      session.info = info;
    } else {
      end('switch');
      _session = _VideoSession(cid, info);
    }
  }

  void onState(
    PlayerStatus status,
    Duration position, {
    required bool isLive,
    required double speed,
  }) {
    final ctr = PlPlayerController.instance;
    final cid = ctr?.cid;
    final now = DateTime.now().millisecondsSinceEpoch;
    final playing = status == PlayerStatus.playing;

    // 只在开始播放时切换，避免旧视频的暂停事件晚到时把新视频的统计切走。
    if (playing && cid != null && _session?.cid != cid) {
      end('switch');
      _session = _VideoSession(cid, _infoByCid[cid] ?? {'cid': cid});
    }
    final session = _session;
    final posSec = position.inSeconds;
    if (session != null && (cid == null || session.cid == cid)) {
      session.lastPositionSec = posSec;
      session.maxPositionSec = math.max(session.maxPositionSec, posSec);
      _samplePosition(session);
      if (playing) {
        session.playingSinceMs ??= now;
      } else {
        session.stopPlaying(now);
      }
    }

    final name = status.name;
    if (name == _lastStatus) return;
    _lastStatus = name;
    String? bvid;
    try {
      bvid = ctr?.bvid;
    } catch (_) {}
    UsageLog.log('player_$name', {
      'bvid': bvid,
      'cid': cid,
      'position_sec': posSec,
      'speed': speed,
      if (isLive) 'live': true,
    });
  }

  /// 播放器只在状态变化（播放、暂停、缓冲）时上报位置；汇总前直接读一次播放器的当前位置。
  void _samplePosition(_VideoSession session) {
    final ctr = PlPlayerController.instance;
    if (ctr == null || ctr.cid != session.cid) return;
    final pos = ctr.position.value;
    session.lastPositionSec = pos;
    session.maxPositionSec = math.max(session.maxPositionSec, pos);
  }

  /// 当前视频的进度快照（不结束统计）。
  Map<String, Object?> snapshot() {
    final session = _session;
    if (session == null) return const {};
    _samplePosition(session);
    return {'video': session.summary(DateTime.now().millisecondsSinceEpoch)};
  }

  void end(String reason) {
    final session = _session;
    if (session == null) return;
    _session = null;
    _lastStatus = null;
    _samplePosition(session);
    final now = DateTime.now().millisecondsSinceEpoch;
    session.stopPlaying(now);
    UsageLog.log('video_end', {...session.summary(now), 'reason': reason});
  }
}

class _VideoSession {
  _VideoSession(this.cid, this.info)
    : startMs = DateTime.now().millisecondsSinceEpoch;

  final int cid;
  Map<String, Object?> info;
  final int startMs;
  int playedMs = 0;
  int? playingSinceMs;
  int lastPositionSec = 0;
  int maxPositionSec = 0;

  void stopPlaying(int now) {
    final since = playingSinceMs;
    if (since != null) {
      playedMs += math.max(0, now - since);
      playingSinceMs = null;
    }
  }

  Map<String, Object?> summary(int now) {
    final since = playingSinceMs;
    final played = playedMs + (since == null ? 0 : math.max(0, now - since));
    return {
      'kind': info['kind'],
      'bvid': info['bvid'],
      'cid': cid,
      'title': info['title'],
      'owner': info['owner'],
      'duration_sec': info['duration_sec'],
      'opened_sec': (now - startMs) ~/ 1000,
      'played_sec': played ~/ 1000,
      'last_position_sec': lastPositionSec,
      'max_position_sec': maxPositionSec,
    };
  }
}

class _UsageNavigatorObserver extends NavigatorObserver {
  static const _argKeys = {
    'bvid',
    'aid',
    'cid',
    'epId',
    'seasonId',
    'mid',
    'id',
    'roomId',
    'keyword',
    'title',
    'videoType',
    'sourceType',
    'isVertical',
  };

  static String? _name(Route<dynamic>? route) {
    final name = route?.settings.name;
    if (name == null) return null;
    final query = name.indexOf('?');
    return query < 0 ? name : name.substring(0, query);
  }

  static Map<String, Object?> _args(Route<dynamic> route) {
    final args = route.settings.arguments;
    final result = <String, Object?>{};
    if (args is Map) {
      for (final key in _argKeys) {
        final value = args[key];
        switch (value) {
          case String():
            result[key] = value.length > 200 ? value.substring(0, 200) : value;
          case num() || bool():
            result[key] = value;
          case Enum():
            result[key] = value.name;
        }
      }
    }
    final name = route.settings.name;
    final query = name?.indexOf('?') ?? -1;
    if (query >= 0) result['query'] = name!.substring(query + 1);
    return result;
  }

  void _enter(Route<dynamic> route, Route<dynamic>? previous, String how) {
    if (route is! PageRoute) return;
    UsageLog.log('page_enter', {
      'page': _name(route),
      'from': _name(previous),
      'how': how,
      ..._args(route),
    });
  }

  void _leave(Route<dynamic> route, Route<dynamic>? next, String how) {
    if (route is! PageRoute) return;
    final page = _name(route);
    UsageLog.log('page_leave', {'page': page, 'to': _name(next), 'how': how});
    if (page == '/videoV') UsageLog._video.end('leave');
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _enter(route, previousRoute, 'push');

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _leave(route, previousRoute, 'pop');

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _leave(route, previousRoute, 'remove');

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _leave(oldRoute, newRoute, 'replace');
    if (newRoute != null) _enter(newRoute, oldRoute, 'replace');
  }
}
