part of 'usage_log.dart';

/// 以 cid 区分「当前在看的视频」，统计每个视频的播放时长、看过的内容和操作。
class _VideoTracker {
  final Map<int, Map<String, Object?>> _infoByCid = {};
  _VideoSession? session;
  String? _lastStatus;

  /// 下一次跳转进度的原因，由 [UsageLog.seekReason] 设置，用一次即清除。
  /// 设置后没有真正跳转（如播放器已释放）时，过一会儿自动失效。
  ({String reason, int atMs})? _seekReason;

  set seekReason(String reason) =>
      _seekReason = (reason: reason, atMs: UsageLog._now());

  void onInfo(int cid, Map<String, Object?> info) {
    _infoByCid.remove(cid);
    _infoByCid[cid] = info;
    if (_infoByCid.length > 50) _infoByCid.remove(_infoByCid.keys.first);
    final session = this.session;
    if (session != null && session.cid == cid) {
      session
        ..info = info
        ..attach();
    } else {
      end('switch');
      this.session = _VideoSession(cid, info)..attach();
    }
  }

  /// 当前播放器播放的是 [session] 时返回它。
  _VideoSession? _current(int? cid) {
    final session = this.session;
    if (session == null) return null;
    return cid == null || session.cid == cid ? session : null;
  }

  void onState(
    PlayerStatus status,
    Duration position, {
    required bool isLive,
    required double speed,
  }) {
    final ctr = PlPlayerController.instance;
    final cid = ctr?.cid;
    final now = UsageLog._now();
    final playing = status == PlayerStatus.playing;

    // 只在开始播放时切换，避免旧视频的暂停事件晚到时把新视频的统计切走。
    if (playing && cid != null && session?.cid != cid) {
      end('switch');
      session = _VideoSession(cid, _infoByCid[cid] ?? {'cid': cid})..attach();
    }
    final current = _current(cid);
    final posSec = position.inSeconds;
    if (current != null) {
      current.updatePosition(posSec);
      _samplePosition(current);
      switch (status) {
        case PlayerStatus.playing:
          current.firstPlayMs ??= now;
          // 播完后双击重播等不经过 seekTo 的重播。经过 seekTo 的在 onSeek 中计数。
          if (current.lastStatus == PlayerStatus.completed &&
              !current.replayCounted) {
            current.replays++;
          }
          current
            ..replayCounted = false
            ..playingSinceMs ??= now;
        case PlayerStatus.completed:
          current
            ..completed = true
            ..stopPlaying(now);
        case PlayerStatus.paused:
          current.stopPlaying(now);
      }
      current.lastStatus = status;
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

  void onPosition(int positionSec, int? cid) {
    _current(cid)?.onTick(positionSec);
  }

  void onSeek(int fromMs, int toMs) {
    final pending = _seekReason;
    _seekReason = null;
    final reason = pending != null && UsageLog._now() - pending.atMs < 2000
        ? pending.reason
        : null;
    if ((toMs - fromMs).abs() < 1000) return;
    final ctr = PlPlayerController.instance;
    final session = _current(ctr?.cid);
    final fromSec = fromMs ~/ 1000;
    final toSec = toMs ~/ 1000;
    session?.onSeek(fromSec, toSec, reason);
    UsageLog.log('player_seek', {
      'bvid': session?.bvid,
      'cid': ctr?.cid,
      'from_sec': fromSec,
      'to_sec': toSec,
      'reason': reason ?? 'user',
    });
  }

  void onSpeed(double from, double to, {required bool longPress}) {
    final ctr = PlPlayerController.instance;
    final session = _current(ctr?.cid);
    if (session != null) {
      session.speedChanges++;
      session.maxSpeed = math.max(session.maxSpeed, to);
    }
    UsageLog.log('player_speed', {
      'bvid': session?.bvid,
      'cid': ctr?.cid,
      'from': from,
      'to': to,
      if (longPress) 'long_press': true,
      'position_sec': ctr?.position.value,
    });
  }

  void onFullscreen(bool fullscreen) {
    final ctr = PlPlayerController.instance;
    final session = _current(ctr?.cid);
    session?.setFullscreen(fullscreen, UsageLog._now());
    UsageLog.log('player_fullscreen', {
      'bvid': session?.bvid,
      'cid': ctr?.cid,
      'on': fullscreen,
      'position_sec': ctr?.position.value,
    });
  }

  /// 前后台切换前调用，把这之前的播放时长记到切换前的前台或后台时长里。
  void beforeForegroundChange(int now) {
    session?.splitPlaying(now);
  }

  /// 播放器只在状态变化（播放、暂停、缓冲）时上报位置；汇总前直接读一次播放器的当前位置。
  void _samplePosition(_VideoSession session) {
    final ctr = PlPlayerController.instance;
    if (ctr == null || ctr.cid != session.cid) return;
    session.updatePosition(ctr.position.value);
  }

  /// 当前视频的进度快照（不结束统计）。
  Map<String, Object?> snapshot() {
    final session = this.session;
    if (session == null) return const {};
    _samplePosition(session);
    return {'video': session.summary(UsageLog._now())};
  }

  void end(String reason) {
    final session = this.session;
    if (session == null) return;
    this.session = null;
    _lastStatus = null;
    _samplePosition(session);
    final now = UsageLog._now();
    session
      ..stopPlaying(now)
      ..setFullscreen(false, now);
    UsageLog.log('video_end', {...session.summary(now), 'reason': reason});
  }
}

class _VideoSession {
  _VideoSession(this.cid, this.info) : startMs = UsageLog._now();

  /// 记录看过哪些秒的上限（10 小时），超出部分不计入覆盖率。
  static const _maxTrackedSec = 36000;

  final int cid;
  Map<String, Object?> info;
  final int startMs;

  /// 点卡片或外部链接打开时的归因（impression_id、来源、位置等）。
  Map<String, Object?>? attribution;

  PlayerStatus? lastStatus;
  int? firstPlayMs;
  int? playingSinceMs;
  int foregroundPlayedMs = 0;
  int backgroundPlayedMs = 0;
  int? fullscreenSinceMs;
  int fullscreenMs = 0;

  int lastPositionSec = 0;
  int maxPositionSec = 0;
  bool completed = false;
  int replays = 0;
  bool replayCounted = false;

  int seeks = 0;
  int seekForwardSec = 0;
  int seekBackwardSec = 0;
  int autoSkippedSec = 0;

  int speedChanges = 0;
  double maxSpeed = 1;

  /// 连续播放经过的内容秒数（不含跳转），以及每一秒被看过的次数。
  int watchedSec = 0;
  Uint8List _watchCount = Uint8List(0);
  int? _lastTickSec;

  String? get bvid => info['bvid'] as String?;

  /// 从最近一次点击中取出归因。只取一次，之后从历史记录等处重新打开时不再算作这次点击。
  void attach() {
    attribution ??= UsageLog._attributionForVideo(bvid);
  }

  void updatePosition(int sec) {
    lastPositionSec = sec;
    maxPositionSec = math.max(maxPositionSec, sec);
  }

  /// 播放位置每秒的变化。前进 1～2 秒视为连续播放（倍速时可能一次前进 2 秒），
  /// 其他变化是跳转，不计入看过的内容。
  void onTick(int sec) {
    updatePosition(sec);
    final last = _lastTickSec;
    _lastTickSec = sec;
    if (last == null) return;
    final delta = sec - last;
    if (delta < 1 || delta > 2) return;
    for (var s = last; s < sec; s++) {
      _markWatched(s);
    }
  }

  void _markWatched(int sec) {
    watchedSec++;
    if (sec < 0 || sec >= _maxTrackedSec) return;
    if (sec >= _watchCount.length) {
      final durationSec = info['duration_sec'];
      final size = math.min(
        _maxTrackedSec,
        math.max(
          math.max(sec + 1, _watchCount.length * 2),
          durationSec is int ? durationSec : 0,
        ),
      );
      _watchCount = Uint8List(size)..setAll(0, _watchCount);
    }
    if (_watchCount[sec] < 255) _watchCount[sec]++;
  }

  void onSeek(int fromSec, int toSec, String? reason) {
    _lastTickSec = null;
    final delta = toSec - fromSec;
    switch (reason) {
      case 'sponsor_skip':
        if (delta > 0) autoSkippedSec += delta;
        return;
      case 'replay':
        replays++;
        replayCounted = true;
        return;
    }
    seeks++;
    if (delta > 0) {
      seekForwardSec += delta;
    } else {
      seekBackwardSec -= delta;
    }
  }

  void stopPlaying(int now) {
    final since = playingSinceMs;
    if (since == null) return;
    playingSinceMs = null;
    final ms = math.max(0, now - since);
    if (UsageLog._foreground) {
      foregroundPlayedMs += ms;
    } else {
      backgroundPlayedMs += ms;
    }
  }

  void splitPlaying(int now) {
    if (playingSinceMs == null) return;
    stopPlaying(now);
    playingSinceMs = now;
  }

  void setFullscreen(bool fullscreen, int now) {
    final since = fullscreenSinceMs;
    if (fullscreen) {
      fullscreenSinceMs ??= now;
    } else if (since != null) {
      fullscreenMs += math.max(0, now - since);
      fullscreenSinceMs = null;
    }
  }

  int playedSec(int now) {
    final since = playingSinceMs;
    final running = since == null ? 0 : math.max(0, now - since);
    return (foregroundPlayedMs + backgroundPlayedMs + running) ~/ 1000;
  }

  Map<String, Object?> summary(int now) {
    final since = playingSinceMs;
    final running = since == null ? 0 : math.max(0, now - since);
    final backgroundMs =
        backgroundPlayedMs + (UsageLog._foreground ? 0 : running);
    final fsSince = fullscreenSinceMs;
    final fullscreen =
        fullscreenMs + (fsSince == null ? 0 : math.max(0, now - fsSince));

    var uniqueSec = 0;
    var rewatchSec = 0;
    for (final count in _watchCount) {
      if (count > 0) {
        uniqueSec++;
        rewatchSec += count - 1;
      }
    }
    final durationSec = info['duration_sec'];
    final firstPlay = firstPlayMs;

    return {
      'kind': info['kind'],
      'bvid': bvid,
      'cid': cid,
      'title': info['title'],
      'owner': info['owner'],
      'owner_mid': info['owner_mid'],
      'duration_sec': durationSec,
      'opened_sec': (now - startMs) ~/ 1000,
      'first_play_after_ms': firstPlay == null ? null : firstPlay - startMs,
      'played_sec': playedSec(now),
      'background_played_sec': backgroundMs ~/ 1000,
      'fullscreen_sec': fullscreen ~/ 1000,
      'watched_sec': watchedSec,
      'unique_sec': uniqueSec,
      'rewatch_sec': rewatchSec,
      if (durationSec is int && durationSec > 0)
        'coverage': (uniqueSec / durationSec * 1000).round() / 1000,
      'last_position_sec': lastPositionSec,
      'max_position_sec': maxPositionSec,
      'completed': completed,
      'replays': replays,
      'seeks': seeks,
      'seek_forward_sec': seekForwardSec,
      'seek_backward_sec': seekBackwardSec,
      'auto_skipped_sec': autoSkippedSec,
      'speed_changes': speedChanges,
      'max_speed': maxSpeed,
      ...?attribution,
    };
  }
}
