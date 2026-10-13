// 使用行为记录：把页面切换、视频曝光与观看、列表刷新、互动反馈等事件写入 PiliPlus 自己的
// SQLite 数据库（应用支持目录下的 usage_log.db），长期保存。事件先在内存里攒一小批再写入，
// 写入失败时保留在内存里稍后重试，不影响 PiliPlus 本身。
//
// 表结构：
//   events(id, timestamp_ms, event_type, session_id, data)
//     data 为其余字段的 JSON，可用 json_extract(data, '$.bvid') 等查询。
//   impressions(impression_id, session_id, shown_ms, source, request_id, position,
//               bvid, aid, owner_mid, visible_ms, episodes, max_ratio, clicked_ms, data)
//     列表里真正显示在屏幕上的视频卡片，每张卡片一行；data 为当时的视频信息快照。
//
// 会话：每次冷启动，或在后台超过 30 分钟后回到前台，开始一个新会话（session_id）。
//
// 一条完整样本的串联方式：
//   impressions.impression_id → card_click → page_enter / video_end 中的 impression_id，
//   list_refresh / list_load_more 的 request_id 对应 impressions.request_id。
//
// 转发给「本地时间采集」应用（com.wind.timetracker，见 UsageLogBridge.kt）的接口保留，
// 目前停用，见 [UsageLog._forwardToTimeTracker]。
//
// 事件类型：
//   app_start / app_foreground / app_background   含网络类型 net、横竖屏 orient
//   network_change                  网络类型变化
//   deep_link                       通过外部链接打开（分享链接等）
//   page_enter / page_leave         页面（路由）进入与离开；点卡片进入的带 impression_id 等归因字段，
//                                   其他方式进入的视频页带 source（history、home:bangumi、dynamics、
//                                   watchLater、page:member 等）；视频页内换视频的观看 source 为 in_page
//   nav_tab / home_tab              底部导航、首页顶部分区切换
//   list_refresh / list_load_more   列表下拉刷新（含首次加载）与上滑加载更多，带 request_id
//   search                          搜索（关键词、类型、排序）
//   card_click                      点击视频卡片，带 impression_id、来源和位置
//   video_info                      视频详情加载完成（标题、UP 主、时长等）
//   player_playing / player_paused / player_completed  播放状态变化
//   player_seek / player_speed / player_fullscreen      拖动进度、倍速、全屏
//   video_end                       一个视频的观看结束（离开、切换），附观看汇总
//   feedback                        点赞、投币、收藏、三连、点踩、不感兴趣、关注、拉黑、稍后再看、分享
//   log_error                       有记录写不进数据库而被丢弃（错误信息和丢弃条数）

import 'dart:async';
import 'dart:collection' show LinkedHashMap;
import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:math' as math;
import 'dart:ui' show FlutterView, PlatformDispatcher;

import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pb.dart' show DetailItem;
import 'package:PiliPlus/models/home/rcmd/result.dart';
import 'package:PiliPlus/models/horizontal_video_model.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/models/model_rec_video_item.dart';
import 'package:PiliPlus/models/model_video.dart';
import 'package:PiliPlus/models/search/result.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/live/live_room_info_h5/data.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/episode.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/models_new/video/video_tag/data.dart';
import 'package:PiliPlus/pages/hot/controller.dart';
import 'package:PiliPlus/pages/member_video_web/base/controller.dart';
import 'package:PiliPlus/pages/popular_precious/controller.dart';
import 'package:PiliPlus/pages/popular_series/controller.dart';
import 'package:PiliPlus/pages/rank/zone/controller.dart';
import 'package:PiliPlus/pages/rcmd/controller.dart';
import 'package:PiliPlus/pages/search_panel/controller.dart';
import 'package:PiliPlus/pages/video/related/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_utils.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

part 'usage_log_impression.dart';
part 'usage_log_video.dart';

abstract final class UsageLog {
  /// 是否同时把事件转发给「本地时间采集」。目前停用，只保留接口。
  static const _forwardToTimeTracker = false;
  static const _channel = MethodChannel('piliplus/usage_log');

  static const _dbName = 'usage_log.db';
  static const _schemaVersion = 2;

  static const _flushDelay = Duration(seconds: 3);
  static const _retryDelay = Duration(seconds: 30);
  static const _flushBatchSize = 50;
  static const _maxQueue = 2000;

  /// 在后台超过这个时长后回到前台，算作新会话。
  static const _newSessionAfter = Duration(minutes: 30);

  /// 点击卡片后，这段时间内进入的页面才认为是这次点击打开的。
  static const _attributionTimeout = Duration(seconds: 15);

  static Database? _db;
  static bool get _enabled => _db != null;

  static final List<Map<String, Object?>> _queue = [];

  /// 待写入的曝光，按 impression_id 去重，只保留最新状态。
  static final LinkedHashMap<String, _Impression> _impressionQueue =
      LinkedHashMap();
  static Timer? _flushTimer;
  static bool _failing = false;
  static AppLifecycleListener? _lifecycleListener;
  static bool _foreground = true;
  static int? _backgroundSinceMs;
  static final int _startMs = _now();

  static String _sessionId = _newSessionId();
  static int _idSeq = 0;

  static String? _network;

  static final NavigatorObserver navigatorObserver = _UsageNavigatorObserver();

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  static String _newSessionId() {
    final random = math.Random().nextInt(36 * 36 * 36 * 36);
    return '${_now().toRadixString(36)}${random.toRadixString(36).padLeft(4, '0')}';
  }

  /// 会话内唯一、全局不重复的 ID，用于曝光、列表请求等。
  static String _nextId(String prefix) =>
      '$_sessionId-$prefix${(++_idSeq).toRadixString(36)}';

  /// 在 runApp 之前、appSupportDirPath 初始化之后调用。
  static void init() {
    if (_db != null) return;
    try {
      _db = _openDb(path.join(appSupportDirPath, _dbName));
    } catch (e) {
      if (kDebugMode) debugPrint('UsageLog init error: $e');
      return;
    }
    // 用 show/hide 而不是 resume/pause：下拉通知栏等只会进入 inactive，
    // 会触发 resume 但不是真正回到前台。
    _lifecycleListener ??= AppLifecycleListener(
      onShow: _onShow,
      onHide: _onHide,
      onDetach: _flushNow,
    );
    _watchNetwork();
    log('app_start', {
      'platform': Platform.operatingSystem,
      ..._context(),
    });
  }

  static void _onShow() {
    if (_foreground) return;
    final now = _now();
    _video.beforeForegroundChange(now);
    _foreground = true;
    final since = _backgroundSinceMs;
    _backgroundSinceMs = null;
    final backgroundMs = since == null ? null : now - since;
    final newSession =
        backgroundMs != null && backgroundMs >= _newSessionAfter.inMilliseconds;
    if (newSession) {
      _sessionId = _newSessionId();
      _idSeq = 0;
    }
    log('app_foreground', {
      'background_sec': backgroundMs == null ? null : backgroundMs ~/ 1000,
      if (newSession) 'new_session': true,
      ..._context(),
    });
    _Impressions.onForegroundChange();
  }

  static void _onHide() {
    if (_foreground) {
      final now = _now();
      _Impressions.endAll(now);
      _video.beforeForegroundChange(now);
      _foreground = false;
      _backgroundSinceMs = now;
      log('app_background', {..._video.snapshot(), ..._context()});
      _Impressions.onForegroundChange();
    }
    _flushNow();
  }

  // ---- 上下文 ----

  static Map<String, Object?> _context() => {
    'net': _network,
    'orient': _orientation(),
  };

  static String? _orientation() {
    final view =
        PlatformDispatcher.instance.implicitView ??
        PlatformDispatcher.instance.views.firstOrNull;
    final size = view?.physicalSize;
    if (size == null || size.isEmpty) return null;
    return size.width > size.height ? 'landscape' : 'portrait';
  }

  static void _watchNetwork() {
    try {
      final connectivity = Connectivity();
      connectivity.checkConnectivity().then(_onNetwork, onError: (_) {});
      // 与应用同生命周期，只在 init 中调用一次，不需要取消。
      connectivity.onConnectivityChanged.listen(
        _onNetwork,
        onError: (_) {},
      );
    } catch (e) {
      if (kDebugMode) debugPrint('UsageLog network error: $e');
    }
  }

  static void _onNetwork(List<ConnectivityResult> results) {
    final String name;
    if (results.contains(ConnectivityResult.wifi)) {
      name = 'wifi';
    } else if (results.contains(ConnectivityResult.ethernet)) {
      name = 'ethernet';
    } else if (results.contains(ConnectivityResult.mobile)) {
      name = 'mobile';
    } else if (results.isEmpty || results.contains(ConnectivityResult.none)) {
      name = 'none';
    } else {
      name = results.first.name;
    }
    final previous = _network;
    if (name == previous) return;
    _network = name;
    if (previous != null) {
      log('network_change', {'net': name, 'from': previous});
    }
  }

  // ---- 数据库 ----

  static Database _openDb(String file) {
    final db = sqlite3.open(file);
    try {
      db
        ..execute('PRAGMA journal_mode = WAL')
        ..execute('PRAGMA synchronous = NORMAL');
      final version = db.userVersion;
      if (version < _schemaVersion) {
        db.execute('BEGIN');
        try {
          if (version < 1) {
            db
              ..execute('''
                CREATE TABLE IF NOT EXISTS events (
                  id INTEGER PRIMARY KEY,
                  timestamp_ms INTEGER NOT NULL,
                  event_type TEXT NOT NULL,
                  data TEXT NOT NULL
                ) STRICT''')
              ..execute(
                'CREATE INDEX IF NOT EXISTS events_time '
                'ON events (timestamp_ms)',
              )
              ..execute(
                'CREATE INDEX IF NOT EXISTS events_type_time '
                'ON events (event_type, timestamp_ms)',
              );
          }
          if (version < 2) {
            db
              ..execute('ALTER TABLE events ADD COLUMN session_id TEXT')
              ..execute('''
                CREATE TABLE IF NOT EXISTS impressions (
                  impression_id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL,
                  shown_ms INTEGER NOT NULL,
                  source TEXT NOT NULL,
                  request_id TEXT,
                  position INTEGER,
                  bvid TEXT,
                  aid INTEGER,
                  owner_mid INTEGER,
                  visible_ms INTEGER NOT NULL,
                  episodes INTEGER NOT NULL,
                  max_ratio REAL NOT NULL,
                  clicked_ms INTEGER,
                  data TEXT NOT NULL
                ) STRICT''')
              ..execute(
                'CREATE INDEX IF NOT EXISTS impressions_time '
                'ON impressions (shown_ms)',
              )
              ..execute(
                'CREATE INDEX IF NOT EXISTS impressions_bvid '
                'ON impressions (bvid)',
              );
          }
          db
            ..userVersion = _schemaVersion
            ..execute('COMMIT');
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
      }
      return db;
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  static void log(String type, Map<String, Object?> fields) {
    if (!_enabled) return;
    _queue.add({
      'timestamp_ms': _now(),
      'event_type': type,
      'session_id': _sessionId,
      for (final e in fields.entries)
        if (e.value != null) e.key: e.value,
    });
    if (_queue.length > _maxQueue) {
      _queue.removeRange(0, _queue.length - _maxQueue);
    }
    _scheduleFlush();
  }

  static void _queueImpression(_Impression impression) {
    if (!_enabled) return;
    _impressionQueue
      ..remove(impression.id)
      ..[impression.id] = impression;
    while (_impressionQueue.length > _maxQueue) {
      _impressionQueue.remove(_impressionQueue.keys.first);
    }
    _scheduleFlush();
  }

  static void _scheduleFlush() {
    // 写入失败后等重试计时器，不因为事件增多而反复立即重试。
    if (_queue.length + _impressionQueue.length >= _flushBatchSize &&
        !_failing) {
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

  static void _flush() {
    final db = _db;
    if (db == null || (_queue.isEmpty && _impressionQueue.isEmpty)) return;
    final batch = List.of(_queue);
    final impressions = List.of(_impressionQueue.values);
    try {
      _write(db, batch, impressions);
    } catch (e) {
      if (_isBadRecord(e)) {
        _writeEach(db, batch, impressions);
      } else {
        _onWriteError(e);
      }
      return;
    }
    _failing = false;
    _queue.removeRange(0, batch.length);
    // 写入是同步的，期间不会有新的曝光状态进来。
    _impressionQueue.clear();
    if (_forwardToTimeTracker) _forward(batch);
  }

  /// 记录本身写不进去（违反约束、无法编码等），重试也不会成功。
  static bool _isBadRecord(Object e) =>
      e is Error ||
      (e is SqliteException &&
          const {
            18, // SQLITE_TOOBIG
            19, // SQLITE_CONSTRAINT
            20, // SQLITE_MISMATCH
            25, // SQLITE_RANGE
          }.contains(e.resultCode));

  /// 整批中有坏记录时逐条写入，丢掉坏的并记一条 log_error，免得它卡住之后的所有记录。
  static void _writeEach(
    Database db,
    List<Map<String, Object?>> batch,
    List<_Impression> impressions,
  ) {
    final written = <Map<String, Object?>>[];
    final errors = <String>{};
    var droppedEvents = 0;
    var droppedImpressions = 0;
    var doneEvents = 0;
    Object? fatal;
    try {
      for (final event in batch) {
        if (_writeOne(db, [event], const []) case final e?) {
          droppedEvents++;
          errors.add('${event['event_type']}: $e');
        } else {
          written.add(event);
        }
        doneEvents++;
      }
      for (final impression in impressions) {
        if (_writeOne(db, const [], [impression]) case final e?) {
          droppedImpressions++;
          errors.add('impression: $e');
        }
        _impressionQueue.remove(impression.id);
      }
    } catch (e) {
      fatal = e;
    }
    _queue.removeRange(0, doneEvents);
    if (_forwardToTimeTracker && written.isNotEmpty) _forward(written);
    if (errors.isNotEmpty) {
      final error = errors.join('\n');
      debugPrint('UsageLog dropped records: $error');
      log('log_error', {
        'error': error.length > 1000 ? error.substring(0, 1000) : error,
        'dropped_events': droppedEvents,
        'dropped_impressions': droppedImpressions,
      });
    }
    if (fatal != null) {
      _onWriteError(fatal);
    } else {
      _failing = false;
    }
  }

  /// 单独写入。记录本身有问题时返回错误，其他错误照常抛出。
  static Object? _writeOne(
    Database db,
    List<Map<String, Object?>> events,
    List<_Impression> impressions,
  ) {
    try {
      _write(db, events, impressions);
      return null;
    } catch (e) {
      if (_isBadRecord(e)) return e;
      rethrow;
    }
  }

  /// 磁盘满、数据库被锁等暂时性错误：保留全部记录，稍后重试。
  static void _onWriteError(Object e) {
    debugPrint('UsageLog write error: $e');
    _failing = true;
    _flushTimer ??= Timer(_retryDelay, _flushNow);
  }

  /// 在一个事务里写入，失败时回滚并抛出。
  static void _write(
    Database db,
    List<Map<String, Object?>> batch,
    List<_Impression> impressions,
  ) {
    db.execute('BEGIN');
    try {
      if (batch.isNotEmpty) {
        final stmt = db.prepare(
          'INSERT INTO events (timestamp_ms, event_type, session_id, data) '
          'VALUES (?, ?, ?, ?)',
        );
        try {
          for (final event in batch) {
            final data = Map.of(event)
              ..remove('timestamp_ms')
              ..remove('event_type')
              ..remove('session_id');
            stmt.execute([
              event['timestamp_ms'],
              event['event_type'],
              event['session_id'],
              jsonEncode(data),
            ]);
          }
        } finally {
          stmt.close();
        }
      }
      if (impressions.isNotEmpty) {
        final stmt = db.prepare('''
          INSERT INTO impressions (impression_id, session_id, shown_ms, source,
            request_id, position, bvid, aid, owner_mid, visible_ms, episodes,
            max_ratio, clicked_ms, data)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (impression_id) DO UPDATE SET
            visible_ms = excluded.visible_ms,
            episodes = excluded.episodes,
            max_ratio = excluded.max_ratio,
            clicked_ms = excluded.clicked_ms''');
        try {
          for (final impression in impressions) {
            stmt.execute(impression.row());
          }
        } finally {
          stmt.close();
        }
      }
      db.execute('COMMIT');
    } catch (_) {
      try {
        db.execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    }
  }

  /// 把全部记录导出为一个独立的 SQLite 数据库文件，由用户选择保存位置。
  static Future<void> export() async {
    final db = _db;
    if (db == null) {
      SmartDialog.showToast('使用记录未启用');
      return;
    }
    _flushNow();
    final tmp = File(path.join(tmpDirPath, 'usage_log_export.db'));
    final Uint8List bytes;
    try {
      if (tmp.existsSync()) tmp.deleteSync();
      // VACUUM INTO 生成一份一致的副本，不受 WAL 中未合并内容影响。
      db.execute('VACUUM INTO ?', [tmp.path]);
      bytes = await tmp.readAsBytes();
    } catch (e) {
      SmartDialog.showToast('导出失败: $e');
      return;
    } finally {
      if (tmp.existsSync()) tmp.deleteSync();
    }
    await StorageUtils.saveBytes2File(
      name:
          'piliplus_usage_log_'
          '${DateFormatUtils.only0_9.format(DateTime.now())}.db',
      bytes: bytes,
      allowedExtensions: const ['db'],
    );
  }

  /// 转发给「本地时间采集」（Android，UsageLogBridge.kt）。数据库才是权威记录，
  /// 转发失败的事件直接丢弃，不重试。
  static Future<void> _forward(List<Map<String, Object?>> batch) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<int>('send', jsonEncode(batch));
    } catch (e) {
      if (kDebugMode) debugPrint('UsageLog forward error: $e');
    }
  }

  // ---- 列表 ----

  /// 列表开始请求数据：isRefresh 为下拉刷新或首次加载，否则为上滑加载更多。
  /// 返回本次请求的 ID，数据返回后交给 [listResponse]。
  static String? listQuery(Object controller, bool isRefresh, int page) {
    if (!_enabled) return null;
    final requestId = _nextId('r');
    final source = _listSource(controller);
    log(isRefresh ? 'list_refresh' : 'list_load_more', {
      'list': controller.runtimeType.toString(),
      'source': source.name,
      'page': page,
      'request_id': requestId,
      ...source.context,
    });
    if (isRefresh && controller is SearchPanelController) {
      log('search', {'request_id': requestId, ...source.context});
    }
    return requestId;
  }

  /// 给列表请求返回的视频记下来源，曝光和点击时使用。offset 为这批数据在列表中的起始位置。
  static void listResponse(
    Object controller,
    String? requestId,
    List<Object?> items,
    int offset,
  ) {
    if (requestId == null) return;
    final source = _listSource(controller);
    for (var i = 0; i < items.length; i++) {
      if (items[i] case final BaseSimpleVideoItemModel item) {
        _Impressions.tag(
          item,
          _ListTag(source.name, requestId, offset + i, source.context),
        );
      }
    }
  }

  static _ListSource _listSource(Object controller) => switch (controller) {
    RcmdController(:final appRcmd) => (
      name: appRcmd ? 'rcmd_app' : 'rcmd_web',
      context: const {},
    ),
    HotController() => (name: 'hot', context: const {}),
    RelatedController(:final bvid) => (
      name: 'related',
      context: {'from_bvid': bvid},
    ),
    SearchPanelController(:final keyword, :final searchType, :final order) => (
      name: 'search',
      context: {
        'keyword': keyword,
        'search_type': searchType.name,
        if (order.isNotEmpty) 'order': order,
      },
    ),
    ZoneController(:final rid, :final seasonType) => (
      name: 'rank',
      context: {'rid': rid, 'season_type': seasonType},
    ),
    PopularPreciousController() => (name: 'precious', context: const {}),
    PopularSeriesController() => (name: 'weekly', context: const {}),
    BaseVideoWebCtr(:final mid) => (
      name: 'member_video',
      context: {'mid': mid.toString()},
    ),
    _ => (name: controller.runtimeType.toString(), context: const {}),
  };

  // ---- 曝光与点击 ----

  /// 包住视频卡片，记录它真正显示在屏幕上的曝光。
  static Widget impression(
    BaseSimpleVideoItemModel item, {
    required Widget child,
  }) {
    if (!_enabled) return child;
    return _ImpressionTracker(item: item, child: child);
  }

  /// 点击视频卡片。之后打开的视频页和观看汇总会带上这次曝光的 ID。
  static void cardClick(BaseSimpleVideoItemModel item) {
    if (!_enabled) return;
    final impression = _Impressions.clicked(item, _now());
    log('card_click', {
      'bvid': impression.bvid,
      'aid': impression.aid,
      ...impression.attribution(),
    });
    _pendingAttribution = (
      atMs: _now(),
      bvid: impression.bvid,
      fields: impression.attribution(),
    );
  }

  /// 通过外部链接打开（分享链接、浏览器跳转等）。
  static void deepLink(Uri uri) {
    if (!_enabled) return;
    final text = uri.toString();
    final sinceStartMs = _now() - _startMs;
    log('deep_link', {
      'uri': text.length > 300 ? text.substring(0, 300) : text,
      'since_start_sec': sinceStartMs ~/ 1000,
      if (sinceStartMs < 10000) 'cold_start': true,
    });
    _pendingAttribution = (
      atMs: _now(),
      bvid: null,
      fields: const {'source': 'deep_link'},
    );
  }

  static ({int atMs, String? bvid, Map<String, Object?> fields})?
  _pendingAttribution;

  /// 最近点击打开的视频，按 bvid 记下归因，留给之后开始的观看统计使用。
  static final LinkedHashMap<String, Map<String, Object?>> _attributionByBvid =
      LinkedHashMap();

  /// 最近一次被页面取走的归因。bvid 为页面知道的视频；给拿不到 bvid 的观看（直播等），
  /// 以及页面参数里没有 bvid 的视频使用。
  static ({int atMs, String? bvid, Map<String, Object?> fields})?
  _recentAttribution;

  /// 开始观看统计时取归因：有 bvid 时按 bvid 取，取不到时用刚刚打开、但不知道是哪个视频的页面的。
  static Map<String, Object?>? _attributionForVideo(String? bvid) {
    final recent = _recentAttribution;
    if (bvid != null) {
      final fields = _attributionByBvid.remove(bvid);
      if (fields != null) {
        if (identical(fields, recent?.fields)) _recentAttribution = null;
        return fields;
      }
    }
    if (recent == null ||
        (bvid != null && recent.bvid != null) ||
        _now() - recent.atMs > _attributionTimeout.inMilliseconds) {
      return null;
    }
    _recentAttribution = null;
    return recent.fields;
  }

  /// 进入页面时取出等待中的点击归因。bvid 为页面参数里的视频，和点击的视频不一致时不使用。
  static Map<String, Object?>? _takeAttribution(String? bvid) {
    final pending = _pendingAttribution;
    if (pending == null) return null;
    if (_now() - pending.atMs > _attributionTimeout.inMilliseconds) {
      _pendingAttribution = null;
      return null;
    }
    if (bvid != null && pending.bvid != null && bvid != pending.bvid) {
      return null;
    }
    _pendingAttribution = null;
    _remember(bvid ?? pending.bvid, pending.fields, pending.atMs);
    return pending.fields;
  }

  /// 记下页面的归因，留给之后开始的观看统计。
  static void _remember(String? bvid, Map<String, Object?> fields, int atMs) {
    _recentAttribution = (atMs: atMs, bvid: bvid, fields: fields);
    if (bvid != null) {
      _attributionByBvid
        ..remove(bvid)
        ..[bvid] = fields;
      if (_attributionByBvid.length > 20) {
        _attributionByBvid.remove(_attributionByBvid.keys.first);
      }
    }
  }

  // ---- 导航 ----

  static String? _navTab;
  static String? _homeTab;

  /// 底部导航切换。initial 为启动时的默认页，只记下不写事件。
  static void navTab(String? tab, {bool initial = false}) {
    if (tab == null) return;
    _navTab = tab;
    if (!initial) log('nav_tab', {'tab': tab});
  }

  /// 首页顶部分区切换。initial 为启动时的默认分区，只记下不写事件。
  static void homeTab(String? tab, {bool initial = false}) {
    if (tab == null) return;
    _homeTab = tab;
    if (!initial) log('home_tab', {'tab': tab});
  }

  /// 不是点卡片打开的视频页，按从哪里进来标记来源。sourceType 为视频页参数，
  /// 稍后再看、收藏夹、UP 主投稿列表等播放列表会带上。
  static Map<String, Object?> _navAttribution(String? from, Object? sourceType) {
    final String source;
    if (sourceType is String && sourceType != 'normal') {
      source = sourceType;
    } else if (from == '/') {
      // 首页各分区里不是视频卡片的入口（番剧、直播等），以及动态、我的页面。
      source = _navTab == null || _navTab == 'home'
          ? 'home:${_homeTab ?? 'unknown'}'
          : _navTab!;
    } else if (from != null) {
      source = 'page:${from.substring(1)}';
    } else {
      source = 'unknown';
    }
    return {'source': source};
  }

  // ---- 互动反馈 ----

  /// 点赞、投币、收藏等操作成功后调用。action 见文件开头的说明。
  static void feedback(
    String action, {
    String? bvid,
    Object? aid,
    Object? mid,
    Map<String, Object?> extra = const {},
  }) {
    if (!_enabled) return;
    if (bvid == null) {
      final aidInt = switch (aid) {
        final int value => value,
        final String value => int.tryParse(value),
        _ => null,
      };
      if (aidInt != null && aidInt > 0) {
        try {
          bvid = IdUtils.av2bv(aidInt);
        } catch (_) {}
      }
    }
    final session = _video.session;
    final inSession = session != null && bvid != null && session.bvid == bvid;
    final Object? impressionId;
    if (inSession) {
      impressionId = session.attribution?['impression_id'];
    } else {
      impressionId = bvid == null ? null : _Impressions.lastIdForBvid(bvid);
    }
    log('feedback', {
      'action': action,
      'bvid': bvid,
      'aid': aid,
      'mid': mid,
      if (inSession) ...{
        'position_sec': session.lastPositionSec,
        'played_sec': session.playedSec(_now()),
      },
      if (session != null && !inSession) 'playing_bvid': session.bvid,
      'impression_id': impressionId,
      ...extra,
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

  /// 视频标签加载完成（比详情晚到），补到这个视频的观看统计里。
  static void videoTags(String bvid, List<VideoTagItem>? tags) {
    if (!_enabled || tags == null) return;
    final names = [
      for (final tag in tags)
        if (tag.tagName case final name? when name.isNotEmpty) name,
    ];
    if (names.isEmpty) return;
    _video.onTags(bvid, names.length > 20 ? names.sublist(0, 20) : names);
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

  /// 播放位置每变化一秒调用一次，用来统计实际看过的内容。
  static void playerPosition(int positionSec, int? cid) {
    if (!_enabled) return;
    _video.onPosition(positionSec, cid);
  }

  /// 标记下一次跳转进度的原因（自动跳过片段、重播等），未标记的视为手动拖动。
  static void seekReason(String reason) {
    if (!_enabled) return;
    _video.seekReason = reason;
  }

  static void playerSeek(int fromMs, int toMs) {
    if (!_enabled) return;
    _video.onSeek(fromMs, toMs);
  }

  static void playerSpeed(double from, double to, {bool longPress = false}) {
    if (!_enabled) return;
    _video.onSpeed(from, to, longPress: longPress);
  }

  static void playerFullscreen(bool fullscreen) {
    if (!_enabled) return;
    _video.onFullscreen(fullscreen);
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
          // 接口目前只给分区 ID，名称多为空字符串。
          'tid': data.tid,
          'tid_v2': data.tidV2,
          'tname': data.tnameV2 ?? data.tname,
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
        // 视频页内切换分 P，只给出分 P 本身。从播放器取 bvid，
        // 再用之前加载的整个视频的信息补全，与首次加载多 P 视频时的格式一致。
        String? bvid;
        try {
          bvid = PlPlayerController.instance?.bvid;
        } catch (_) {}
        final parent = bvid == null ? null : _video.ugcInfo(bvid);
        if (parent == null) {
          return {
            'kind': 'part',
            'bvid': bvid,
            'cid': cid,
            'title': data.part,
            'owner': artist,
            'duration_sec': data.duration,
          };
        }
        return {
          ...parent,
          'cid': cid,
          'duration_sec': data.duration,
          'part': data.part,
          'part_index': data.page,
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

  /// 离开这些页面时结束当前视频的观看统计。
  static const _playerPages = {'/videoV', '/liveRoom'};

  /// Get.to(() => ...) 以闭包的静态返回类型作路由名，返回类型不具体时只得到这些名字；
  /// Navigator.push 未设置 settings 时路由名为空。这两种情况从组件树里取实际页面。
  static const _genericNames = {
    '/Widget',
    '/StatelessWidget',
    '/StatefulWidget',
  };
  static final _resolvedNames = Expando<String>('usageLogRouteName');

  static String? _name(Route<dynamic>? route) {
    if (route == null) return null;
    final resolved = _resolvedNames[route];
    if (resolved != null) return resolved;
    final name = route.settings.name;
    if (name == null) return null;
    final query = name.indexOf('?');
    return query < 0 ? name : name.substring(0, query);
  }

  static bool _needsResolve(String? name) =>
      name == null || _genericNames.contains(name);

  /// 路由内容为 RepaintBoundary → Builder → Semantics → 页面，跳过这几层取页面类型。
  static String? _resolveName(ModalRoute<dynamic> route) {
    Element? element = route.subtreeContext as Element?;
    for (var depth = 0; element != null && depth < 6; depth++) {
      final widget = element.widget;
      if (widget is! RepaintBoundary &&
          widget is! Builder &&
          widget is! Semantics) {
        return '/${widget.runtimeType}';
      }
      Element? child;
      element.visitChildren((e) => child ??= e);
      element = child;
    }
    return null;
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
    if (_needsResolve(_name(route))) {
      // 页面要在下一帧构建后才能从组件树里取到。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final resolved = _resolveName(route);
        if (resolved != null) _resolvedNames[route] = resolved;
        _logEnter(route, previous, how);
      });
    } else {
      _logEnter(route, previous, how);
    }
  }

  void _logEnter(Route<dynamic> route, Route<dynamic>? previous, String how) {
    final args = _args(route);
    final bvid = args['bvid'] is String ? args['bvid'] as String : null;
    var attribution = UsageLog._takeAttribution(bvid);
    final page = _name(route);
    if (attribution == null && _playerPages.contains(page)) {
      attribution = UsageLog._navAttribution(
        _name(previous),
        args['sourceType'],
      );
      UsageLog._remember(bvid, attribution, UsageLog._now());
    }
    UsageLog.log('page_enter', {
      'page': page,
      'from': _name(previous),
      'how': how,
      ...args,
      ...?attribution,
    });
  }

  void _leave(Route<dynamic> route, Route<dynamic>? next, String how) {
    if (route is! PageRoute) return;
    final page = _name(route);
    UsageLog.log('page_leave', {'page': page, 'to': _name(next), 'how': how});
    if (_playerPages.contains(page)) UsageLog._video.end('leave');
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
