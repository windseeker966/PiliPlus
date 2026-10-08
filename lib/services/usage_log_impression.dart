part of 'usage_log.dart';

typedef _ListSource = ({String name, Map<String, Object?> context});

/// 列表请求返回时给每个视频记下的来源。
class _ListTag {
  const _ListTag(this.source, this.requestId, this.position, this.context);

  final String source;
  final String requestId;

  /// 在整个列表中的位置（从 0 开始），按请求返回时计算。
  final int position;

  /// 列表的附加信息，如搜索词、相关视频所属的视频。
  final Map<String, Object?> context;
}

/// 一张视频卡片的曝光。同一个视频对象在列表里多次进出屏幕，算同一次曝光的多个片段。
class _Impression {
  _Impression(BaseSimpleVideoItemModel item, _ListTag? tag, String? page)
    : id = UsageLog._nextId('i'),
      sessionId = UsageLog._sessionId,
      shownMs = UsageLog._now(),
      source = tag?.source ?? 'page:${page ?? 'unknown'}',
      requestId = tag?.requestId,
      position = tag?.position {
    int? aid;
    String? bvid;
    try {
      if (item is BaseVideoItemModel) aid = item.aid;
      bvid = item.bvid ?? (aid != null && aid > 0 ? IdUtils.av2bv(aid) : null);
    } catch (_) {}
    this.aid = aid;
    this.bvid = bvid;
    try {
      ownerMid = item.owner.mid;
    } catch (_) {}
    data = {
      ..._snapshot(item),
      ...?tag?.context,
      if (tag != null && page != null) 'page': page,
      ...UsageLog._context(),
    };
  }

  final String id;
  final String sessionId;
  final int shownMs;
  final String source;
  final String? requestId;
  final int? position;
  late final String? bvid;
  late final int? aid;
  int? ownerMid;
  late final Map<String, Object?> data;

  int visibleMs = 0;
  int episodes = 0;
  double maxRatio = 0;
  int? clickedMs;

  /// 点击后带到页面和观看统计里的归因字段。
  Map<String, Object?> attribution() => {
    'impression_id': id,
    'source': source,
    'request_id': requestId,
    'position': position,
  };

  List<Object?> row() => [
    id,
    sessionId,
    shownMs,
    source,
    requestId,
    position,
    bvid,
    aid,
    ownerMid,
    visibleMs,
    episodes,
    maxRatio,
    clickedMs,
    jsonEncode(data),
  ];

  /// 曝光时卡片上的信息。播放、点赞等数字会变化，记下当时的值。
  static Map<String, Object?> _snapshot(BaseSimpleVideoItemModel item) {
    final result = <String, Object?>{};
    void put(String key, Object? value) {
      if (value != null) result[key] = value;
    }

    try {
      put('title', item.title);
      put('cid', item.cid);
      if (item.duration > 0) put('duration_sec', item.duration);
      put('owner', item.owner.name);
      final stat = item.stat;
      put('view', stat.view);
      put('like', stat.like);
      put('danmaku', stat.danmu);
      if (stat case final HotStat stat) {
        put('reply', stat.reply);
        put('favorite', stat.favorite);
        put('coin', stat.coin);
        put('share', stat.share);
      } else if (stat case final SearchStat stat) {
        put('reply', stat.reply);
        put('favorite', stat.favorite);
      }
      if (item is BaseVideoItemModel) {
        put('pubdate', item.pubdate);
        if (item.isFollowed) put('followed', true);
      }
      if (item is BaseRcmdVideoItemModel) {
        put('goto', item.goto);
        put('rcmd_reason', item.rcmdReason);
      }
      if (item is RcmdVideoItemAppModel) put('card_type', item.cardType);
      if (item is HotVideoItemModel) {
        put('tid', item.tid);
        put('tname', item.tname);
      }
      if (item is HorizontalVideoModel) {
        put('badge', item.badge);
        if (item.isLive == true) put('live', true);
        if (item.isPugv == true) put('pugv', true);
        if (item.progress case final progress? when progress != 0) {
          put('progress', progress);
        }
      }
    } catch (_) {}
    return result;
  }
}

abstract final class _Impressions {
  /// 卡片露出至少这个比例、持续至少这么久，才算一次曝光。
  static const _minRatio = 0.5;
  static const _minVisibleMs = 500;
  static const _tickInterval = Duration(milliseconds: 250);

  static final _tags = Expando<_ListTag>('usageLogListTag');
  static final _impressions = Expando<_Impression>('usageLogImpression');
  static final Set<_ImpressionTrackerState> _trackers = {};
  static Timer? _timer;

  /// 最近曝光过的视频，用于把卡片上的「不感兴趣」等操作对应到曝光。
  static final LinkedHashMap<String, String> _lastIdByBvid = LinkedHashMap();

  static void tag(BaseSimpleVideoItemModel item, _ListTag tag) {
    _tags[item] ??= tag;
  }

  static String? lastIdForBvid(String bvid) => _lastIdByBvid[bvid];

  static _Impression _getOrCreate(
    BaseSimpleVideoItemModel item,
    String? page,
  ) {
    var impression = _impressions[item];
    if (impression == null) {
      impression = _Impression(item, _tags[item], page);
      _impressions[item] = impression;
      if (impression.bvid case final bvid?) {
        _lastIdByBvid
          ..remove(bvid)
          ..[bvid] = impression.id;
        if (_lastIdByBvid.length > 500) {
          _lastIdByBvid.remove(_lastIdByBvid.keys.first);
        }
      }
    }
    return impression;
  }

  /// 点击卡片。卡片还没满足曝光条件（比如露出不到 0.5 秒就点了）时也记一次曝光。
  static _Impression clicked(BaseSimpleVideoItemModel item, int now) {
    String? page;
    for (final tracker in _trackers) {
      if (identical(tracker.widget.item, item)) {
        page = tracker.page;
        break;
      }
    }
    final impression = _getOrCreate(item, page);
    if (impression.episodes == 0) impression.episodes = 1;
    impression.clickedMs ??= now;
    UsageLog._queueImpression(impression);
    return impression;
  }

  static void _add(_ImpressionTrackerState tracker) {
    _trackers.add(tracker);
    _updateTimer();
  }

  static void _remove(_ImpressionTrackerState tracker) {
    _trackers.remove(tracker);
    _updateTimer();
  }

  static void onForegroundChange() => _updateTimer();

  static void _updateTimer() {
    final run = _trackers.isNotEmpty && UsageLog._foreground;
    if (run) {
      _timer ??= Timer.periodic(_tickInterval, _tick);
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  static void _tick(Timer _) {
    final now = UsageLog._now();
    for (final tracker in List.of(_trackers)) {
      tracker.tick(now);
    }
  }

  static void endAll(int now) {
    for (final tracker in _trackers) {
      tracker.endEpisode(now);
    }
  }
}

class _ImpressionTracker extends StatefulWidget {
  const _ImpressionTracker({required this.item, required this.child});

  final BaseSimpleVideoItemModel item;
  final Widget child;

  @override
  State<_ImpressionTracker> createState() => _ImpressionTrackerState();
}

class _ImpressionTrackerState extends State<_ImpressionTracker> {
  /// 所在页面在最上层且没有被暂停（如隐藏的 Tab）。
  bool _active = true;
  String? page;
  ScrollableState? _scrollable;
  FlutterView? _view;

  int? _episodeStartMs;
  double _episodeMaxRatio = 0;
  bool _counted = false;

  @override
  void initState() {
    super.initState();
    _Impressions._add(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    _active =
        (route?.isCurrent ?? true) && TickerMode.valuesOf(context).enabled;
    page = _UsageNavigatorObserver._name(route);
    _scrollable = Scrollable.maybeOf(context);
    _view = View.maybeOf(context);
    if (!_active) endEpisode(UsageLog._now());
  }

  @override
  void didUpdateWidget(_ImpressionTracker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.item, widget.item)) {
      _endEpisode(oldWidget.item, UsageLog._now());
    }
  }

  @override
  void dispose() {
    endEpisode(UsageLog._now());
    _Impressions._remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;

  void tick(int now) {
    final ratio = _active ? _visibleRatio() : 0.0;
    if (ratio < _Impressions._minRatio) {
      endEpisode(now);
      return;
    }
    final start = _episodeStartMs ??= now;
    _episodeMaxRatio = math.max(_episodeMaxRatio, ratio);
    if (!_counted && now - start >= _Impressions._minVisibleMs) {
      _counted = true;
      final impression = _Impressions._getOrCreate(widget.item, page)
        ..episodes += 1;
      impression.maxRatio = math.max(impression.maxRatio, _episodeMaxRatio);
      UsageLog._queueImpression(impression);
    }
  }

  void endEpisode(int now) => _endEpisode(widget.item, now);

  void _endEpisode(BaseSimpleVideoItemModel item, int now) {
    final start = _episodeStartMs;
    if (start == null) return;
    _episodeStartMs = null;
    if (_counted) {
      if (_Impressions._impressions[item] case final impression?) {
        impression
          ..visibleMs += math.max(0, now - start)
          ..maxRatio = math.max(impression.maxRatio, _episodeMaxRatio);
        UsageLog._queueImpression(impression);
      }
    }
    _counted = false;
    _episodeMaxRatio = 0;
  }

  /// 卡片在屏幕和所在滚动区域内露出的面积比例。
  double _visibleRatio() {
    final view = _view;
    if (!mounted || view == null || view.physicalSize.isEmpty) return 0;
    final screen = Offset.zero & (view.physicalSize / view.devicePixelRatio);
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return 0;
    final rect = _globalRect(box);
    if (rect.width <= 0 || rect.height <= 0) return 0;
    var clip = screen;
    final scrollable = _scrollable;
    if (scrollable != null && scrollable.mounted) {
      final scrollBox = scrollable.context.findRenderObject();
      if (scrollBox is RenderBox && scrollBox.attached && scrollBox.hasSize) {
        clip = clip.intersect(_globalRect(scrollBox));
      }
    }
    final visible = rect.intersect(clip);
    if (visible.width <= 0 || visible.height <= 0) return 0;
    return (visible.width * visible.height) / (rect.width * rect.height);
  }

  static Rect _globalRect(RenderBox box) => MatrixUtils.transformRect(
    box.getTransformTo(null),
    Offset.zero & box.size,
  );
}
