import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';

import '../browse/playback_handoff.dart';
import 'playback_transport.dart';

const playbackStartupDeadline = Duration(seconds: 20);
const playbackCheckpointInterval = Duration(seconds: 10);
const playbackResumeMinimumWatched = Duration(seconds: 30);
const playbackResumeMinimumRemaining = Duration(seconds: 60);

typedef PlaybackManagerTransportFactory = PlaybackTransport Function();

/// Resolves credentials and imported locators just in time. Implementations
/// must not log or persist the returned target.
abstract interface class PlaybackTargetResolverPort {
  Future<PlaybackResolvedTarget> resolve(PlaybackHandoff handoff);
}

/// Supplies the already-effective per-source stream limit. The persistence
/// adapter owns local-override -> provider-report -> conservative-one policy.
abstract interface class PlaybackAdmissionPort {
  Future<int> effectiveLimitForSource(String sourceId);
}

abstract interface class PlaybackProgressPort {
  Future<PlaybackCheckpoint?> load(PlaybackProgressIdentity identity);
  Future<bool> save(
    PlaybackProgressIdentity identity,
    PlaybackCheckpoint checkpoint,
  );
  Future<bool> clear(PlaybackProgressIdentity identity);
}

class PlaybackResolvedTarget {
  PlaybackResolvedTarget({
    required this.uri,
    Map<String, String> httpHeaders = const {},
  }) : httpHeaders = UnmodifiableMapView(Map<String, String>.from(httpHeaders));

  final Uri uri;
  final Map<String, String> httpHeaders;

  @override
  String toString() => 'PlaybackResolvedTarget(redacted)';
}

enum PlaybackSessionFailure { credentialsUnavailable, unavailable, timedOut }

class PlaybackResolutionException implements Exception {
  const PlaybackResolutionException(this.failure);

  final PlaybackSessionFailure failure;

  @override
  String toString() => 'PlaybackResolutionException(redacted)';
}

class PlaybackCheckpoint {
  const PlaybackCheckpoint({
    required this.position,
    required this.duration,
    required this.updatedAt,
    this.completed = false,
    this.watched = Duration.zero,
  });

  final Duration position;
  final Duration duration;
  final DateTime updatedAt;
  final bool completed;
  final Duration watched;

  @override
  String toString() => 'PlaybackCheckpoint(redacted)';
}

/// Returns the automatic resume seek, or zero for fresh/near-finished media.
@visibleForTesting
Duration eligibleResumePosition(PlaybackCheckpoint? checkpoint) {
  if (checkpoint == null ||
      checkpoint.completed ||
      checkpoint.watched < playbackResumeMinimumWatched ||
      checkpoint.duration <= Duration.zero ||
      checkpoint.position >= checkpoint.duration ||
      checkpoint.duration - checkpoint.position <
          playbackResumeMinimumRemaining) {
    return Duration.zero;
  }
  return checkpoint.position;
}

class PlaybackSessionId {
  const PlaybackSessionId._(this.value);

  final int value;

  @override
  bool operator ==(Object other) =>
      other is PlaybackSessionId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'PlaybackSessionId(redacted)';
}

enum PlaybackSessionPhase { opening, ready, buffering, failed }

class PlaybackSessionMetrics {
  const PlaybackSessionMetrics({
    required this.attempts,
    required this.requestedAt,
    this.firstVideoAt,
  });

  final int attempts;
  final DateTime requestedAt;
  final DateTime? firstVideoAt;

  Duration? get startupLatency => firstVideoAt?.difference(requestedAt);

  @override
  String toString() => 'PlaybackSessionMetrics(redacted)';
}

class PlaybackSessionSnapshot {
  const PlaybackSessionSnapshot({
    required this.id,
    required this.title,
    required this.mediaKind,
    required this.phase,
    required this.transportState,
    required this.isAudible,
    required this.metrics,
    required this.resume,
    required this.progressSaveFailed,
    this.failure,
  });

  final PlaybackSessionId id;
  final String title;
  final PlaybackMediaKind mediaKind;
  final PlaybackSessionPhase phase;
  final PlaybackTransportState transportState;
  final bool isAudible;
  final PlaybackSessionMetrics metrics;
  final PlaybackResumeSnapshot resume;
  final bool progressSaveFailed;
  final PlaybackSessionFailure? failure;

  @override
  String toString() => 'PlaybackSessionSnapshot(redacted)';
}

class PlaybackResumeSnapshot {
  const PlaybackResumeSnapshot({
    this.appliedPosition = Duration.zero,
    this.loadFailed = false,
  });

  final Duration appliedPosition;
  final bool loadFailed;

  bool get didResume => appliedPosition > Duration.zero;

  @override
  String toString() => 'PlaybackResumeSnapshot(redacted)';
}

class PlaybackStartOverOutcome {
  const PlaybackStartOverOutcome({
    required this.seekSucceeded,
    required this.progressSaved,
  });

  final bool seekSucceeded;
  final bool progressSaved;

  bool get succeeded => seekSucceeded && progressSaved;

  @override
  String toString() => 'PlaybackStartOverOutcome(redacted)';
}

enum PlaybackBlockReason { globalMaximum, sourceLimit, managerClosed }

sealed class PlaybackStartResult {
  const PlaybackStartResult();

  @override
  String toString() => '$runtimeType(redacted)';
}

final class PlaybackStarted extends PlaybackStartResult {
  const PlaybackStarted(this.sessionId);

  final PlaybackSessionId sessionId;
}

final class PlaybackStartFailed extends PlaybackStartResult {
  const PlaybackStartFailed(this.sessionId, this.failure);

  final PlaybackSessionId sessionId;
  final PlaybackSessionFailure failure;
}

final class PlaybackBlocked extends PlaybackStartResult {
  const PlaybackBlocked(this.reason, {this.effectiveLimit});

  final PlaybackBlockReason reason;
  final int? effectiveLimit;
}

class PlaybackManager extends ChangeNotifier {
  PlaybackManager({
    required this.targetResolver,
    PlaybackAdmissionPort? admissionPort,
    PlaybackProgressPort? progressPort,
    PlaybackManagerTransportFactory? transportFactory,
    this.startupDeadline = playbackStartupDeadline,
    DateTime Function()? clock,
  }) : _admissionPort = admissionPort ?? const _ConservativeAdmissionPort(),
       _progressPort = progressPort ?? const _NoPlaybackProgressPort(),
       _transportFactory = transportFactory ?? MediaKitPlaybackTransport.create,
       _clock = clock ?? DateTime.now;

  static const maximumSessions = 2;

  final PlaybackTargetResolverPort targetResolver;
  final PlaybackAdmissionPort _admissionPort;
  final PlaybackProgressPort _progressPort;
  final PlaybackManagerTransportFactory _transportFactory;
  final DateTime Function() _clock;
  final Duration startupDeadline;

  final LinkedHashMap<PlaybackSessionId, _ManagedPlaybackSession> _sessions =
      LinkedHashMap();
  Future<void> _operationTail = Future<void>.value();
  Future<void>? _closing;
  PlaybackSessionId? _audioOwner;
  int _nextSessionId = 1;
  bool _closed = false;
  bool _canNotify = true;

  List<PlaybackSessionSnapshot> get sessions =>
      List.unmodifiable(_sessions.values.map(_snapshot));

  PlaybackSessionSnapshot? session(PlaybackSessionId id) {
    final value = _sessions[id];
    return value == null ? null : _snapshot(value);
  }

  Widget videoFor(PlaybackSessionId id) =>
      _sessions[id]?.transport?.buildVideo() ?? const SizedBox.expand();

  Future<PlaybackStartResult> start(
    PlaybackHandoff handoff, {
    PlaybackSessionId? replaceSessionId,
    bool requestAudioFocus = true,
  }) => _serialized(() async {
    if (_closed) {
      return const PlaybackBlocked(PlaybackBlockReason.managerClosed);
    }
    final replacement = replaceSessionId == null
        ? null
        : _sessions[replaceSessionId];
    final retainedSessionCount =
        _sessions.length - (replacement == null ? 0 : 1);
    if (retainedSessionCount >= maximumSessions) {
      return const PlaybackBlocked(PlaybackBlockReason.globalMaximum);
    }

    var effectiveLimit = 1;
    try {
      effectiveLimit = await _admissionPort.effectiveLimitForSource(
        handoff.sourceId,
      );
    } catch (_) {
      effectiveLimit = 1;
    }
    effectiveLimit = effectiveLimit.clamp(1, maximumSessions);
    final admittedForSource = _sessions.values
        .where(
          (session) =>
              !identical(session, replacement) &&
              session.handoff.sourceId == handoff.sourceId &&
              session.failure == null,
        )
        .length;
    if (admittedForSource >= effectiveLimit) {
      return PlaybackBlocked(
        PlaybackBlockReason.sourceLimit,
        effectiveLimit: effectiveLimit,
      );
    }
    if (replacement != null) {
      await _removeSessionNow(replacement.id);
    }

    final id = PlaybackSessionId._(_nextSessionId++);
    final managed = _ManagedPlaybackSession(
      id: id,
      handoff: handoff,
      requestedAt: _clock(),
    );
    _sessions[id] = managed;
    _notify();

    final identity = handoff.progressIdentity;
    if (identity != null) {
      try {
        final checkpoint = await _progressPort.load(identity);
        managed
          ..watched = checkpoint?.watched ?? Duration.zero
          ..resumePosition = eligibleResumePosition(checkpoint);
      } catch (_) {
        managed.resumePosition = Duration.zero;
        managed.resumeLoadFailed = true;
      }
    }

    final failure = await _openWithQuietRetry(managed);
    if (failure != null) {
      await _makeTerminal(managed, failure);
      return PlaybackStartFailed(id, failure);
    }
    if (requestAudioFocus || _audioOwner == null) {
      await _setAudioOwnerNow(id);
    }
    _notify();
    return PlaybackStarted(id);
  });

  Future<bool> retry(PlaybackSessionId id) => _serialized(() async {
    final managed = _sessions[id];
    if (_closed || managed == null || managed.failure == null) return false;
    managed
      ..failure = null
      ..attempts = 0
      ..firstVideoAt = null;
    _notify();
    final failure = await _openWithQuietRetry(managed);
    if (failure != null) {
      await _makeTerminal(managed, failure);
      return false;
    }
    if (_audioOwner == null) await _setAudioOwnerNow(id);
    _notify();
    return true;
  });

  Future<void> stop(PlaybackSessionId id) {
    final managed = _sessions[id];
    if (managed != null) managed.stopRequested = true;
    _interruptOpen(managed);
    return _serialized(() async {
      if (_sessions.containsKey(id)) await _removeSessionNow(id);
    });
  }

  Future<void> stopAll() {
    for (final managed in _sessions.values) {
      managed.stopRequested = true;
      _interruptOpen(managed);
    }
    return _serialized(() async {
      for (final id in _sessions.keys.toList(growable: false)) {
        await _removeSessionNow(id, selectReplacementOwner: false);
      }
      _audioOwner = null;
      _notify();
    });
  }

  Future<bool> setAudioOwner(PlaybackSessionId id) => _serialized(() async {
    if (_closed || _sessions[id]?.transport == null) return false;
    return _setAudioOwnerNow(id);
  });

  Future<bool> setMuted(PlaybackSessionId id, bool muted) => muted
      ? _serialized(() async {
          final managed = _sessions[id];
          if (_closed || managed?.transport == null) return false;
          if (_audioOwner == id) {
            try {
              await managed!.transport!.setMuted(true);
            } catch (_) {
              // Muting remains best effort; clearing ownership prevents a
              // second session from being declared audible concurrently.
            }
            _audioOwner = null;
            _notify();
          }
          return true;
        })
      : setAudioOwner(id);

  Future<bool> play(PlaybackSessionId id) =>
      _transportCommand(id, (transport) => transport.play());

  Future<bool> pause(PlaybackSessionId id) => _serialized(() async {
    final managed = _sessions[id];
    if (_closed || managed?.transport == null) return false;
    var paused = true;
    try {
      await managed!.transport!.pause();
    } catch (_) {
      paused = false;
    }
    await _flushProgress(managed!);
    return paused;
  });

  Future<bool> seek(PlaybackSessionId id, Duration position) =>
      _serialized(() async {
        final managed = _sessions[id];
        if (_closed || managed?.transport == null) return false;
        final maximum = managed!.state.duration;
        final bounded = position < Duration.zero
            ? Duration.zero
            : maximum > Duration.zero && position > maximum
            ? maximum
            : position;
        try {
          await managed.transport!.seek(bounded);
          managed
            ..pendingProgressSeekPosition = bounded
            ..state = managed.state.copyWith(position: bounded);
          _notify();
          return true;
        } catch (_) {
          return false;
        }
      });

  Future<bool> startOver(PlaybackSessionId id) async =>
      (await startOverWithOutcome(id)).succeeded;

  Future<PlaybackStartOverOutcome> startOverWithOutcome(PlaybackSessionId id) =>
      _serialized(() async {
        final managed = _sessions[id];
        if (_closed || managed?.transport == null) {
          return const PlaybackStartOverOutcome(
            seekSucceeded: false,
            progressSaved: false,
          );
        }
        await managed!.progressTail;
        try {
          await managed.transport!.seek(Duration.zero);
        } catch (_) {
          return const PlaybackStartOverOutcome(
            seekSucceeded: false,
            progressSaved: false,
          );
        }
        var persisted = true;
        final identity = managed.handoff.progressIdentity;
        if (identity != null) {
          try {
            persisted = await _progressPort.clear(identity);
          } catch (_) {
            persisted = false;
          }
        }
        managed
          ..lastQueuedPosition = Duration.zero
          ..resumePosition = Duration.zero
          ..appliedResumePosition = Duration.zero
          ..watched = Duration.zero
          ..pendingProgressSeekPosition = Duration.zero
          ..state = managed.state.copyWith(position: Duration.zero);
        managed.progressSaveFailed = !persisted;
        _notify();
        return PlaybackStartOverOutcome(
          seekSucceeded: true,
          progressSaved: persisted,
        );
      });

  Future<bool> setVolume(PlaybackSessionId id, double volume) =>
      _serialized(() async {
        final transport = _sessions[id]?.transport;
        if (_closed || transport == null || _audioOwner != id) return false;
        try {
          await transport.setVolume(volume.clamp(0, 100));
          return true;
        } catch (_) {
          return false;
        }
      });

  Future<bool> selectAudioTrack(PlaybackSessionId id, String trackId) =>
      _serialized(() async {
        final managed = _sessions[id];
        final transport = managed?.transport;
        if (_closed || transport is! PlaybackTrackTransport) return false;
        if (trackId != 'auto' &&
            !managed!.state.audioTracks.any((track) => track.id == trackId)) {
          return false;
        }
        try {
          await transport.selectAudioTrack(trackId);
          return true;
        } catch (_) {
          return false;
        }
      });

  Future<bool> selectSubtitleTrack(PlaybackSessionId id, String trackId) =>
      _serialized(() async {
        final managed = _sessions[id];
        final transport = managed?.transport;
        if (_closed || transport is! PlaybackTrackTransport) return false;
        if (trackId != 'no' &&
            trackId != 'auto' &&
            !managed!.state.subtitleTracks.any(
              (track) => track.id == trackId,
            )) {
          return false;
        }
        try {
          await transport.selectSubtitleTrack(trackId);
          return true;
        } catch (_) {
          return false;
        }
      });

  Future<bool> _transportCommand(
    PlaybackSessionId id,
    Future<void> Function(PlaybackTransport transport) command,
  ) => _serialized(() async {
    final transport = _sessions[id]?.transport;
    if (_closed || transport == null) return false;
    try {
      await command(transport);
      return true;
    } catch (_) {
      return false;
    }
  });

  Future<PlaybackSessionFailure?> _openWithQuietRetry(
    _ManagedPlaybackSession managed,
  ) async {
    managed
      ..failure = null
      ..opening = true;
    _notify();
    var lastFailure = PlaybackSessionFailure.unavailable;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (_closed ||
          managed.stopRequested ||
          _sessions[managed.id] != managed) {
        managed.opening = false;
        return PlaybackSessionFailure.unavailable;
      }
      managed.attempts += 1;
      _notify();
      final failure = await _openOnce(managed);
      if (_closed ||
          managed.stopRequested ||
          _sessions[managed.id] != managed) {
        managed.opening = false;
        return PlaybackSessionFailure.unavailable;
      }
      if (failure == null) {
        managed.opening = false;
        if (_audioOwner == managed.id) {
          try {
            await managed.transport?.setMuted(false);
          } catch (_) {
            _audioOwner = null;
          }
        }
        return null;
      }
      if (failure == PlaybackSessionFailure.credentialsUnavailable) {
        managed.opening = false;
        return failure;
      }
      lastFailure = failure;
    }
    managed.opening = false;
    return lastFailure;
  }

  Future<PlaybackSessionFailure?> _openOnce(
    _ManagedPlaybackSession managed,
  ) async {
    await _disposeTransport(managed);
    final abort = Completer<void>();
    managed.openAbort = abort;
    final resolution = Completer<_TargetResolution>();
    unawaited(() async {
      try {
        final target = await targetResolver.resolve(managed.handoff);
        if (!resolution.isCompleted) {
          resolution.complete(_TargetResolution(target: target));
        }
      } on PlaybackResolutionException catch (error) {
        if (!resolution.isCompleted) {
          resolution.complete(_TargetResolution(failure: error.failure));
        }
      } catch (_) {
        if (!resolution.isCompleted) {
          resolution.complete(
            const _TargetResolution(
              failure: PlaybackSessionFailure.unavailable,
            ),
          );
        }
      }
    }());
    final resolved =
        await Future.any<_TargetResolution>([
          resolution.future,
          abort.future.then(
            (_) => const _TargetResolution(
              failure: PlaybackSessionFailure.unavailable,
            ),
          ),
        ]).timeout(
          startupDeadline,
          onTimeout: () =>
              const _TargetResolution(failure: PlaybackSessionFailure.timedOut),
        );
    if (resolved.failure != null) {
      if (identical(managed.openAbort, abort)) managed.openAbort = null;
      return resolved.failure;
    }
    final target = resolved.target!;
    if (_closed || managed.stopRequested || _sessions[managed.id] != managed) {
      if (identical(managed.openAbort, abort)) managed.openAbort = null;
      return PlaybackSessionFailure.unavailable;
    }

    final generation = ++managed.generation;
    late final PlaybackTransport transport;
    try {
      transport = _transportFactory();
      managed.transport = transport;
      await transport.setMuted(true);
    } catch (_) {
      await _disposeTransport(managed);
      if (identical(managed.openAbort, abort)) managed.openAbort = null;
      return PlaybackSessionFailure.unavailable;
    }

    final usable = Completer<PlaybackSessionFailure?>();
    managed.subscription = transport.states.listen((next) {
      if (_closed ||
          _sessions[managed.id] != managed ||
          managed.generation != generation ||
          !identical(managed.transport, transport)) {
        return;
      }
      final previous = managed.state;
      managed.state = next;
      if (next.hasVideo && managed.firstVideoAt == null) {
        managed.firstVideoAt = _clock();
      }
      _checkpointFromState(managed, previous, next);
      _notify();
      if (next.hasError) {
        if (!usable.isCompleted) {
          usable.complete(PlaybackSessionFailure.unavailable);
        } else if (!managed.opening && !managed.recovering) {
          unawaited(_serialized(() => _recoverRuntimeError(managed)));
        }
      } else if (next.hasVideo && !usable.isCompleted) {
        usable.complete(null);
      }
    });

    unawaited(
      transport.open(target.uri, httpHeaders: target.httpHeaders).catchError((
        Object _,
      ) {
        if (_sessions[managed.id] == managed &&
            managed.generation == generation &&
            identical(managed.transport, transport) &&
            !usable.isCompleted) {
          usable.complete(PlaybackSessionFailure.unavailable);
        }
      }),
    );

    final result =
        await Future.any<PlaybackSessionFailure?>([
          usable.future,
          abort.future.then((_) => PlaybackSessionFailure.unavailable),
        ]).timeout(
          startupDeadline,
          onTimeout: () => PlaybackSessionFailure.timedOut,
        );
    if (identical(managed.openAbort, abort)) managed.openAbort = null;
    if (result != null ||
        _sessions[managed.id] != managed ||
        managed.generation != generation ||
        managed.state.hasError) {
      return result ?? PlaybackSessionFailure.unavailable;
    }
    final reopen = managed.reopenPosition;
    final resume = managed.resumePosition;
    final seekPosition = reopen > Duration.zero ? reopen : resume;
    if (seekPosition > Duration.zero) {
      final currentDuration = managed.state.duration;
      final stillEligible =
          currentDuration <= Duration.zero ||
          (seekPosition < currentDuration &&
              (reopen > Duration.zero ||
                  currentDuration - seekPosition >=
                      playbackResumeMinimumRemaining));
      if (stillEligible) {
        try {
          await transport.seek(seekPosition);
          managed
            ..pendingProgressSeekPosition = seekPosition
            ..appliedResumePosition = reopen > Duration.zero
                ? managed.appliedResumePosition
                : resume
            ..state = managed.state.copyWith(position: seekPosition);
        } catch (_) {
          // A failed restoration seek leaves otherwise usable playback at zero.
        }
      }
      managed.resumePosition = Duration.zero;
      managed.reopenPosition = Duration.zero;
    }
    return null;
  }

  Future<void> _recoverRuntimeError(_ManagedPlaybackSession managed) async {
    if (_closed ||
        managed.stopRequested ||
        _sessions[managed.id] != managed ||
        managed.recovering ||
        !managed.state.hasError) {
      return;
    }
    managed.recovering = true;
    if (managed.attempts >= 2) {
      await _makeTerminal(managed, PlaybackSessionFailure.unavailable);
      managed.recovering = false;
      return;
    }
    managed.opening = true;
    managed.attempts += 1;
    if (managed.handoff.mediaKind != PlaybackMediaKind.live &&
        managed.state.position > Duration.zero) {
      managed.reopenPosition = managed.state.position;
    }
    _notify();
    final failure = await _openOnce(managed);
    managed
      ..recovering = false
      ..opening = false;
    if (failure != null) {
      await _makeTerminal(managed, failure);
      return;
    }
    if (_audioOwner == managed.id) {
      try {
        await managed.transport?.setMuted(false);
      } catch (_) {
        _audioOwner = null;
      }
    }
    _notify();
  }

  Future<void> _makeTerminal(
    _ManagedPlaybackSession managed,
    PlaybackSessionFailure failure,
  ) async {
    await _disposeTransport(managed);
    managed
      ..opening = false
      ..failure = failure;
    if (_audioOwner == managed.id) _audioOwner = null;
    await _selectReplacementAudioOwner(excluding: managed.id);
    _notify();
  }

  Future<bool> _setAudioOwnerNow(PlaybackSessionId id) async {
    final selected = _sessions[id];
    if (selected?.transport == null) return false;
    final priorOwner = _audioOwner;
    final prior = priorOwner == null ? null : _sessions[priorOwner];
    var priorOwnerMuted = false;

    // The current owner is the first side of the transfer. If it cannot be
    // muted, the candidate must never receive an unmute command and ownership
    // remains where it was.
    if (priorOwner != null && priorOwner != id && prior?.transport != null) {
      try {
        await prior!.transport!.setMuted(true);
        priorOwnerMuted = true;
      } catch (_) {
        _notify();
        return false;
      }
    }

    for (final managed in _sessions.values) {
      if (managed.id == id || managed.id == priorOwner) continue;
      final transport = managed.transport;
      if (transport == null) continue;
      try {
        await transport.setMuted(true);
      } catch (_) {
        // Never enable a second owner while any other transport may be audible.
        if (priorOwnerMuted) {
          try {
            await prior!.transport!.setMuted(false);
            _audioOwner = priorOwner;
          } catch (_) {
            _audioOwner = null;
          }
        }
        _notify();
        return false;
      }
    }
    try {
      await selected!.transport!.setMuted(false);
      _audioOwner = id;
      _notify();
      return true;
    } catch (_) {
      if (priorOwnerMuted) {
        try {
          await prior!.transport!.setMuted(false);
          _audioOwner = priorOwner;
        } catch (_) {
          // Neither side can now be proven audible. Clear the presentation
          // owner rather than label a muted tile as audible.
          _audioOwner = null;
        }
      } else if (priorOwner != id) {
        _audioOwner = null;
      }
      _notify();
      return false;
    }
  }

  Future<void> _selectReplacementAudioOwner({
    PlaybackSessionId? excluding,
  }) async {
    if (_audioOwner != null) return;
    for (final managed in _sessions.values) {
      if (managed.id != excluding && managed.transport != null) {
        await _setAudioOwnerNow(managed.id);
        return;
      }
    }
  }

  void _checkpointFromState(
    _ManagedPlaybackSession managed,
    PlaybackTransportState previous,
    PlaybackTransportState next,
  ) {
    final watchedDelta = next.position - previous.position;
    if (previous.hasVideo &&
        previous.isPlaying &&
        next.isPlaying &&
        watchedDelta > Duration.zero &&
        watchedDelta <= const Duration(seconds: 5)) {
      managed.watched += watchedDelta;
    }
    if (managed.handoff.progressIdentity == null ||
        !next.hasVideo ||
        next.duration <= Duration.zero ||
        next.position < Duration.zero) {
      return;
    }
    final pendingSeek = managed.pendingProgressSeekPosition;
    if (pendingSeek != null) {
      final distance = (next.position - pendingSeek).abs();
      if (distance > const Duration(seconds: 2)) return;
      managed.pendingProgressSeekPosition = null;
    }
    final elapsed = next.position - managed.lastQueuedPosition;
    if (elapsed >= playbackCheckpointInterval ||
        elapsed <= -playbackCheckpointInterval ||
        (previous.isPlaying && !next.isPlaying)) {
      _queueProgress(managed, next.position, next.duration);
    }
  }

  void _queueProgress(
    _ManagedPlaybackSession managed,
    Duration position,
    Duration duration,
  ) {
    final identity = managed.handoff.progressIdentity;
    if (identity == null || duration <= Duration.zero) return;
    managed.lastQueuedPosition = position;
    final checkpoint = PlaybackCheckpoint(
      position: position,
      duration: duration,
      updatedAt: _nextCheckpointTime(managed),
      completed:
          position >= duration ||
          duration - position < playbackResumeMinimumRemaining,
      watched: managed.watched,
    );
    managed.progressTail = managed.progressTail.then((_) async {
      try {
        final saved = await _progressPort.save(identity, checkpoint);
        managed.progressSaveFailed = !saved;
      } catch (_) {
        // Progress is secondary; transport state remains authoritative.
        managed.progressSaveFailed = true;
      }
      _notify();
    });
  }

  DateTime _nextCheckpointTime(_ManagedPlaybackSession managed) {
    var next = _clock().toUtc();
    final previous = managed.lastCheckpointAt;
    if (previous != null && !next.isAfter(previous)) {
      next = previous.add(const Duration(microseconds: 1));
    }
    managed.lastCheckpointAt = next;
    return next;
  }

  Future<void> _flushProgress(_ManagedPlaybackSession managed) async {
    await managed.progressTail;
    final state = managed.state;
    if (managed.handoff.progressIdentity == null ||
        !state.hasVideo ||
        state.duration <= Duration.zero) {
      return;
    }
    _queueProgress(
      managed,
      managed.pendingProgressSeekPosition ?? state.position,
      state.duration,
    );
    await managed.progressTail;
  }

  Future<void> _disposeTransport(_ManagedPlaybackSession managed) async {
    managed.generation += 1;
    final subscription = managed.subscription;
    final transport = managed.transport;
    managed
      ..subscription = null
      ..transport = null
      ..state = const PlaybackTransportState();
    if (subscription != null) {
      try {
        await subscription.cancel();
      } catch (_) {
        // Continue to transport disposal.
      }
    }
    if (transport != null) {
      try {
        await transport.dispose();
      } catch (_) {
        // A disposed logical slot must not retain a failed native object.
      }
    }
  }

  Future<void> _removeSessionNow(
    PlaybackSessionId id, {
    bool selectReplacementOwner = true,
  }) async {
    final managed = _sessions[id];
    if (managed == null) return;
    _interruptOpen(managed);
    await _flushProgress(managed);
    final ownedAudio = _audioOwner == id;
    if (ownedAudio) _audioOwner = null;
    await _disposeTransport(managed);
    _sessions.remove(id);
    if (ownedAudio && selectReplacementOwner) {
      await _selectReplacementAudioOwner();
    }
    _notify();
  }

  PlaybackSessionSnapshot _snapshot(_ManagedPlaybackSession managed) {
    final phase = managed.failure != null
        ? PlaybackSessionPhase.failed
        : managed.opening
        ? PlaybackSessionPhase.opening
        : managed.state.isBuffering
        ? PlaybackSessionPhase.buffering
        : PlaybackSessionPhase.ready;
    return PlaybackSessionSnapshot(
      id: managed.id,
      title: managed.handoff.title,
      mediaKind: managed.handoff.mediaKind,
      phase: phase,
      transportState: managed.state,
      isAudible: _audioOwner == managed.id,
      metrics: PlaybackSessionMetrics(
        attempts: managed.attempts,
        requestedAt: managed.requestedAt,
        firstVideoAt: managed.firstVideoAt,
      ),
      resume: PlaybackResumeSnapshot(
        appliedPosition: managed.appliedResumePosition,
        loadFailed: managed.resumeLoadFailed,
      ),
      progressSaveFailed: managed.progressSaveFailed,
      failure: managed.failure,
    );
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _notify() {
    if (_canNotify && !_closed) notifyListeners();
  }

  Future<void> close() {
    final active = _closing;
    if (active != null) return active;
    _closed = true;
    for (final managed in _sessions.values) {
      managed.stopRequested = true;
      _interruptOpen(managed);
    }
    late final Future<void> closing;
    closing = _operationTail.then((_) async {
      for (final id in _sessions.keys.toList(growable: false)) {
        await _removeSessionNow(id, selectReplacementOwner: false);
      }
      _audioOwner = null;
    });
    _closing = closing;
    return closing;
  }

  @override
  void dispose() {
    _canNotify = false;
    unawaited(close());
    super.dispose();
  }
}

void _interruptOpen(_ManagedPlaybackSession? managed) {
  final abort = managed?.openAbort;
  if (abort != null && !abort.isCompleted) abort.complete();
}

class _TargetResolution {
  const _TargetResolution({this.target, this.failure});

  final PlaybackResolvedTarget? target;
  final PlaybackSessionFailure? failure;
}

class _ManagedPlaybackSession {
  _ManagedPlaybackSession({
    required this.id,
    required this.handoff,
    required this.requestedAt,
  });

  final PlaybackSessionId id;
  final PlaybackHandoff handoff;
  final DateTime requestedAt;
  PlaybackTransport? transport;
  StreamSubscription<PlaybackTransportState>? subscription;
  PlaybackTransportState state = const PlaybackTransportState();
  Future<void> progressTail = Future<void>.value();
  PlaybackSessionFailure? failure;
  DateTime? firstVideoAt;
  DateTime? lastCheckpointAt;
  Duration lastQueuedPosition = Duration.zero;
  Duration resumePosition = Duration.zero;
  Duration appliedResumePosition = Duration.zero;
  Duration reopenPosition = Duration.zero;
  Duration watched = Duration.zero;
  Duration? pendingProgressSeekPosition;
  int attempts = 0;
  int generation = 0;
  bool opening = false;
  bool recovering = false;
  bool resumeLoadFailed = false;
  bool progressSaveFailed = false;
  Completer<void>? openAbort;
  bool stopRequested = false;
}

class _ConservativeAdmissionPort implements PlaybackAdmissionPort {
  const _ConservativeAdmissionPort();

  @override
  Future<int> effectiveLimitForSource(String sourceId) async => 1;
}

class _NoPlaybackProgressPort implements PlaybackProgressPort {
  const _NoPlaybackProgressPort();

  @override
  Future<bool> clear(PlaybackProgressIdentity identity) async => true;

  @override
  Future<PlaybackCheckpoint?> load(PlaybackProgressIdentity identity) async =>
      null;

  @override
  Future<bool> save(
    PlaybackProgressIdentity identity,
    PlaybackCheckpoint checkpoint,
  ) async => true;
}
