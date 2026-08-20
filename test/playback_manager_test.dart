import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/browse/playback_handoff.dart';
import 'package:wabbit_tv/src/features/playback/playback_manager.dart';
import 'package:wabbit_tv/src/features/playback/playback_transport.dart';

void main() {
  test('resume policy starts fresh below 30s and near the end', () {
    final now = DateTime.utc(2026);
    expect(eligibleResumePosition(null), Duration.zero);
    expect(
      eligibleResumePosition(
        PlaybackCheckpoint(
          position: const Duration(seconds: 29),
          duration: const Duration(minutes: 10),
          updatedAt: now,
        ),
      ),
      Duration.zero,
    );
    expect(
      eligibleResumePosition(
        PlaybackCheckpoint(
          position: const Duration(minutes: 9, seconds: 1),
          duration: const Duration(minutes: 10),
          updatedAt: now,
        ),
      ),
      Duration.zero,
    );
    expect(
      eligibleResumePosition(
        PlaybackCheckpoint(
          position: const Duration(minutes: 2),
          duration: const Duration(minutes: 10),
          watched: const Duration(minutes: 2),
          updatedAt: now,
        ),
      ),
      const Duration(minutes: 2),
    );
    expect(
      eligibleResumePosition(
        PlaybackCheckpoint(
          position: const Duration(minutes: 2),
          duration: const Duration(minutes: 10),
          updatedAt: now,
          completed: true,
        ),
      ),
      Duration.zero,
    );
  });

  test('resolved target and failure strings never expose transport data', () {
    final target = PlaybackResolvedTarget(
      uri: Uri.parse('https://stream.example/video?token=private'),
      httpHeaders: const {'Authorization': 'private-header'},
    );

    expect(target.toString(), 'PlaybackResolvedTarget(redacted)');
    expect(target.toString(), isNot(contains('private')));
    expect(() => target.httpHeaders['Other'] = 'value', throwsUnsupportedError);
    expect(
      const PlaybackResolutionException(
        PlaybackSessionFailure.credentialsUnavailable,
      ).toString(),
      'PlaybackResolutionException(redacted)',
    );
  });

  test('episode progress identity is exact and never collapses to series', () {
    const first = EpisodePlaybackHandoff(
      sourceId: 'source',
      title: 'Same title',
      providerItemId: 'episode-1',
      extension: 'mp4',
      libraryItemId: 'series-library-row',
    );
    const second = EpisodePlaybackHandoff(
      sourceId: 'source',
      title: 'Same title',
      providerItemId: 'episode-2',
      extension: 'mp4',
      libraryItemId: 'series-library-row',
    );

    expect(first.progressIdentity!.libraryItemId, 'series-library-row');
    expect(
      first.progressIdentity!.mediaKey,
      isNot(second.progressIdentity!.mediaKey),
    );
    expect(first.progressIdentity.toString(), contains('redacted'));
    expect(first.progressIdentity.toString(), isNot(contains('episode-1')));
  });

  test(
    'movie progress uses its stable local library row plus constant key',
    () {
      const movie = MoviePlaybackHandoff(
        sourceId: 'source',
        title: 'Movie',
        providerItemId: 'provider-id-can-change',
        extension: 'mp4',
        libraryItemId: 'stable-library-row',
      );

      expect(movie.progressIdentity!.libraryItemId, 'stable-library-row');
      expect(movie.progressIdentity!.mediaKey, 'movie');
    },
  );

  test(
    'source admission is atomic and blocked start creates no transport',
    () async {
      final factory = _TransportFactory();
      final manager = PlaybackManager(
        targetResolver: const _Resolver(),
        admissionPort: _Admission({'same': 1}),
        transportFactory: factory.create,
      );

      final results = await Future.wait([
        manager.start(_live('same', 'one')),
        manager.start(_live('same', 'two'), requestAudioFocus: false),
      ]);

      expect(results.first, isA<PlaybackStarted>());
      expect(results.last, isA<PlaybackBlocked>());
      expect(
        (results.last as PlaybackBlocked).reason,
        PlaybackBlockReason.sourceLimit,
      );
      expect(factory.created, hasLength(1));
      expect(manager.sessions, hasLength(1));
      await manager.close();
    },
  );

  test('global manager maximum is two sessions', () async {
    final factory = _TransportFactory();
    final manager = PlaybackManager(
      targetResolver: const _Resolver(),
      admissionPort: _Admission({'a': 2, 'b': 2, 'c': 2}),
      transportFactory: factory.create,
    );

    await manager.start(_live('a', 'one'));
    await manager.start(_live('b', 'two'), requestAudioFocus: false);
    final blocked = await manager.start(_live('c', 'three'));

    expect(blocked, isA<PlaybackBlocked>());
    expect(
      (blocked as PlaybackBlocked).reason,
      PlaybackBlockReason.globalMaximum,
    );
    expect(factory.created, hasLength(2));
    await manager.close();
  });

  test(
    'one quiet retry disposes the failed transport before replacement',
    () async {
      final log = <String>[];
      final factory = _TransportFactory(
        log: log,
        specs: const [_TransportSpec(openFails: true), _TransportSpec()],
      );
      final manager = PlaybackManager(
        targetResolver: const _Resolver(),
        transportFactory: factory.create,
      );

      final result = await manager.start(_live('source', 'private-title'));

      expect(result, isA<PlaybackStarted>());
      expect(factory.created, hasLength(2));
      expect(log.indexOf('dispose-1'), lessThan(log.indexOf('create-2')));
      expect(manager.sessions.single.metrics.attempts, 2);
      expect(
        manager.sessions.single.toString(),
        isNot(contains('private-title')),
      );
      expect(
        manager.sessions.single.transportState.toString(),
        contains('redacted'),
      );
      await manager.close();
    },
  );

  test('two failed attempts end in sanitized terminal state', () async {
    final factory = _TransportFactory(
      specs: const [
        _TransportSpec(openFails: true),
        _TransportSpec(openFails: true),
      ],
    );
    final manager = PlaybackManager(
      targetResolver: const _Resolver(),
      transportFactory: factory.create,
    );

    final result = await manager.start(_live('source', 'secret title'));

    expect(result, isA<PlaybackStartFailed>());
    expect(
      (result as PlaybackStartFailed).failure,
      PlaybackSessionFailure.unavailable,
    );
    expect(manager.sessions.single.phase, PlaybackSessionPhase.failed);
    expect(manager.sessions.single.toString(), isNot(contains('secret title')));
    expect(result.toString(), 'PlaybackStartFailed(redacted)');
    expect(factory.created.every((transport) => transport.disposed), isTrue);
    await manager.close();
  });

  test('startup timeout remains truthful after the one quiet retry', () async {
    final factory = _TransportFactory(
      specs: const [
        _TransportSpec(neverReady: true),
        _TransportSpec(neverReady: true),
      ],
    );
    final manager = PlaybackManager(
      targetResolver: const _Resolver(),
      transportFactory: factory.create,
      startupDeadline: const Duration(milliseconds: 1),
    );

    final result = await manager.start(_live('source', 'live'));

    expect(result, isA<PlaybackStartFailed>());
    expect(
      (result as PlaybackStartFailed).failure,
      PlaybackSessionFailure.timedOut,
    );
    expect(factory.created, hasLength(2));
    await manager.close();
  });

  test(
    'runtime engine error quietly replaces only the current transport',
    () async {
      final log = <String>[];
      final factory = _TransportFactory(log: log);
      final manager = PlaybackManager(
        targetResolver: const _Resolver(),
        transportFactory: factory.create,
      );
      await manager.start(_live('source', 'live'));

      factory.created.first.emit(const PlaybackTransportState(hasError: true));
      for (var i = 0; i < 20 && factory.created.length < 2; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(factory.created, hasLength(2));
      expect(log.indexOf('dispose-1'), lessThan(log.indexOf('create-2')));
      expect(manager.sessions.single.phase, PlaybackSessionPhase.ready);
      expect(manager.sessions.single.metrics.attempts, 2);
      await manager.close();
    },
  );

  test(
    'new sessions start muted and explicit owner transfer never mixes audio',
    () async {
      final log = <String>[];
      final factory = _TransportFactory(log: log);
      final manager = PlaybackManager(
        targetResolver: const _Resolver(),
        admissionPort: _Admission({'source': 2}),
        transportFactory: factory.create,
      );

      final first =
          await manager.start(_live('source', 'one')) as PlaybackStarted;
      final second = await manager.start(
        _live('source', 'two'),
        requestAudioFocus: false,
      ) as PlaybackStarted;

      expect(factory.created[0].muted, isFalse);
      expect(factory.created[1].muted, isTrue);
      expect(manager.session(first.sessionId)!.isAudible, isTrue);
      expect(manager.session(second.sessionId)!.isAudible, isFalse);
      expect(log.indexOf('mute-1-true'), lessThan(log.indexOf('open-1')));
      expect(log.indexOf('open-1'), lessThan(log.indexOf('mute-1-false')));

      await manager.setAudioOwner(second.sessionId);

      expect(factory.created[0].muted, isTrue);
      expect(factory.created[1].muted, isFalse);
      expect(
        log.lastIndexOf('mute-1-true'),
        lessThan(log.lastIndexOf('mute-2-false')),
      );
      expect(
        manager.sessions.where((session) => session.isAudible),
        hasLength(1),
      );
      await manager.close();
    },
  );

  test(
    'replacement disposes and releases old session before constructing new',
    () async {
      final log = <String>[];
      final factory = _TransportFactory(log: log);
      final manager = PlaybackManager(
        targetResolver: const _Resolver(),
        transportFactory: factory.create,
      );
      final first =
          await manager.start(_live('source', 'one')) as PlaybackStarted;

      final replacement = await manager.start(
        _live('source', 'two'),
        replaceSessionId: first.sessionId,
      );

      expect(replacement, isA<PlaybackStarted>());
      expect(log.indexOf('dispose-1'), lessThan(log.indexOf('create-2')));
      expect(manager.sessions, hasLength(1));
      expect(manager.sessions.single.title, 'two');
      await manager.close();
    },
  );

  test(
    'eligible VOD seeks on open, checkpoints by 10s, flushes, and starts over',
    () async {
      final progress = _Progress(
        loaded: PlaybackCheckpoint(
          position: const Duration(seconds: 45),
          duration: const Duration(minutes: 5),
          watched: const Duration(seconds: 45),
          updatedAt: DateTime.utc(2026),
        ),
      );
      final factory = _TransportFactory();
      final manager = PlaybackManager(
        targetResolver: const _Resolver(),
        progressPort: progress,
        transportFactory: factory.create,
        clock: () => DateTime.utc(2026, 1, 1, 0, 0, 1),
      );
      const movie = MoviePlaybackHandoff(
        sourceId: 'source',
        title: 'movie',
        providerItemId: 'movie-1',
        extension: 'mp4',
        libraryItemId: 'library-movie-1',
      );

      final started = await manager.start(movie) as PlaybackStarted;
      final transport = factory.created.single;
      expect(transport.seeks, contains(const Duration(seconds: 45)));

      transport.emit(_ready(position: const Duration(seconds: 45)));
      transport.emit(_ready(position: const Duration(seconds: 55)));
      await manager.pause(started.sessionId);
      expect(
        progress.saved.any(
          (value) => value.position == const Duration(seconds: 55),
        ),
        isTrue,
      );

      expect(await manager.startOver(started.sessionId), isTrue);
      expect(progress.cleared, 1);
      expect(transport.seeks.last, Duration.zero);

      transport.emit(_ready());
      transport.emit(_ready(position: const Duration(seconds: 23)));
      await manager.stop(started.sessionId);
      expect(progress.saved.last.position, const Duration(seconds: 23));
      await manager.close();
    },
  );

  test('live playback never loads or saves fake progress', () async {
    final progress = _Progress();
    final manager = PlaybackManager(
      targetResolver: const _Resolver(),
      progressPort: progress,
      transportFactory: _TransportFactory().create,
    );

    final started =
        await manager.start(_live('source', 'live')) as PlaybackStarted;
    await manager.pause(started.sessionId);
    await manager.stop(started.sessionId);

    expect(progress.loads, 0);
    expect(progress.saved, isEmpty);
    expect(progress.cleared, 0);
    await manager.close();
  });

  test(
    'track DTOs select through optional transport capability only',
    () async {
      final factory = _TransportFactory(
        specs: const [_TransportSpec(withTracks: true)],
      );
      final manager = PlaybackManager(
        targetResolver: const _Resolver(),
        transportFactory: factory.create,
      );
      final started =
          await manager.start(_live('source', 'live')) as PlaybackStarted;

      expect(
        await manager.selectAudioTrack(started.sessionId, 'audio-2'),
        isTrue,
      );
      expect(
        await manager.selectSubtitleTrack(started.sessionId, 'sub-1'),
        isTrue,
      );
      expect(
        await manager.selectAudioTrack(started.sessionId, 'missing'),
        isFalse,
      );
      expect(factory.created.single.selectedAudio, 'audio-2');
      expect(factory.created.single.selectedSubtitle, 'sub-1');
      expect(
        manager.sessions.single.transportState.audioTracks.first.toString(),
        contains('redacted'),
      );
      await manager.close();
    },
  );

  test(
    'disposed transport events cannot overwrite replacement state',
    () async {
      final factory = _TransportFactory();
      final manager = PlaybackManager(
        targetResolver: const _Resolver(),
        transportFactory: factory.create,
      );
      final first =
          await manager.start(_live('source', 'one')) as PlaybackStarted;
      final stale = factory.created.first;
      await manager.start(
        _live('source', 'two'),
        replaceSessionId: first.sessionId,
      );

      stale.emit(const PlaybackTransportState(hasError: true));
      await Future<void>.delayed(Duration.zero);

      expect(manager.sessions.single.title, 'two');
      expect(manager.sessions.single.phase, PlaybackSessionPhase.ready);
      expect(factory.created, hasLength(2));
      await manager.close();
    },
  );

  test('blocked replacement preserves the usable old session', () async {
    final factory = _TransportFactory();
    final manager = PlaybackManager(
      targetResolver: const _Resolver(),
      admissionPort: _Admission({'target': 1, 'old': 1}),
      transportFactory: factory.create,
    );
    await manager.start(_live('target', 'existing'));
    final old = await manager.start(
      _live('old', 'keep me'),
      requestAudioFocus: false,
    ) as PlaybackStarted;

    final blocked = await manager.start(
      _live('target', 'blocked'),
      replaceSessionId: old.sessionId,
    );

    expect(blocked, isA<PlaybackBlocked>());
    expect(factory.created, hasLength(2));
    expect(manager.session(old.sessionId)?.title, 'keep me');
    expect(manager.sessions, hasLength(2));
    await manager.close();
  });

  test('close interrupts a resolver that has not completed', () async {
    final manager = PlaybackManager(
      targetResolver: const _NeverResolver(),
      startupDeadline: const Duration(seconds: 30),
      transportFactory: _TransportFactory().create,
    );
    final opening = manager.start(_live('source', 'opening'));
    await Future<void>.delayed(Duration.zero);

    final watch = Stopwatch()..start();
    await manager.close();
    await opening;

    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(manager.sessions, isEmpty);
  });

  test('stop interrupts a runtime retry waiting for video', () async {
    final factory = _TransportFactory(
      specs: const [_TransportSpec(), _TransportSpec(neverReady: true)],
    );
    final manager = PlaybackManager(
      targetResolver: const _Resolver(),
      transportFactory: factory.create,
      startupDeadline: const Duration(seconds: 30),
    );
    final started =
        await manager.start(_live('source', 'live')) as PlaybackStarted;
    factory.created.first.emit(const PlaybackTransportState(hasError: true));
    for (var i = 0; i < 20 && factory.created.length < 2; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(factory.created, hasLength(2));

    final watch = Stopwatch()..start();
    await manager.stop(started.sessionId);

    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(factory.created.last.disposed, isTrue);
    expect(manager.sessions, isEmpty);
    await manager.close();
  });

  test('runtime retry restores the current VOD position', () async {
    final factory = _TransportFactory();
    final manager = PlaybackManager(
      targetResolver: const _Resolver(),
      transportFactory: factory.create,
    );
    const movie = MoviePlaybackHandoff(
      sourceId: 'source',
      title: 'movie',
      providerItemId: 'movie',
      extension: 'mp4',
      libraryItemId: 'library',
    );
    await manager.start(movie);
    factory.created.first.emit(_ready(position: const Duration(seconds: 72)));
    factory.created.first.emit(
      PlaybackTransportState(
        hasVideo: true,
        hasError: true,
        position: const Duration(seconds: 72),
        duration: const Duration(minutes: 5),
      ),
    );
    for (var i = 0; i < 20 && factory.created.length < 2; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(factory.created.last.seeks, contains(const Duration(seconds: 72)));
    await manager.close();
  });

  test(
    'failed old-owner mute never enables a second audible session',
    () async {
      final factory = _TransportFactory(
        specs: const [
          _TransportSpec(muteFailsAfterOpen: true),
          _TransportSpec(),
        ],
      );
      final manager = PlaybackManager(
        targetResolver: const _Resolver(),
        admissionPort: _Admission({'source': 2}),
        transportFactory: factory.create,
      );
      final first =
          await manager.start(_live('source', 'one')) as PlaybackStarted;
      final second = await manager.start(
        _live('source', 'two'),
        requestAudioFocus: false,
      ) as PlaybackStarted;

      expect(await manager.setAudioOwner(second.sessionId), isFalse);
      expect(manager.session(first.sessionId)!.isAudible, isTrue);
      expect(manager.session(second.sessionId)!.isAudible, isFalse);
      expect(factory.created.last.muted, isTrue);
      expect(
        factory.created.last.muteRequests.where((value) => !value),
        isEmpty,
      );
      expect(await manager.setVolume(second.sessionId, 75), isFalse);
      await manager.close();
    },
  );

  test(
    'failed new-owner unmute rolls audio ownership back to the old owner',
    () async {
      final factory = _TransportFactory();
      final manager = PlaybackManager(
        targetResolver: const _Resolver(),
        admissionPort: _Admission({'source': 2}),
        transportFactory: factory.create,
      );
      final first =
          await manager.start(_live('source', 'one')) as PlaybackStarted;
      final second = await manager.start(
        _live('source', 'two'),
        requestAudioFocus: false,
      ) as PlaybackStarted;
      final oldTransport = factory.created.first;
      final newTransport = factory.created.last..failUnmute = true;

      expect(await manager.setAudioOwner(second.sessionId), isFalse);

      expect(oldTransport.muted, isFalse);
      expect(newTransport.muted, isTrue);
      expect(manager.session(first.sessionId)!.isAudible, isTrue);
      expect(manager.session(second.sessionId)!.isAudible, isFalse);
      await manager.close();
    },
  );

  test(
    'failed new-owner unmute and failed rollback clear audio ownership',
    () async {
      final factory = _TransportFactory();
      final manager = PlaybackManager(
        targetResolver: const _Resolver(),
        admissionPort: _Admission({'source': 2}),
        transportFactory: factory.create,
      );
      final first =
          await manager.start(_live('source', 'one')) as PlaybackStarted;
      final second = await manager.start(
        _live('source', 'two'),
        requestAudioFocus: false,
      ) as PlaybackStarted;
      final oldTransport = factory.created.first..failUnmute = true;
      final newTransport = factory.created.last..failUnmute = true;

      expect(await manager.setAudioOwner(second.sessionId), isFalse);

      expect(oldTransport.muted, isTrue);
      expect(newTransport.muted, isTrue);
      expect(manager.session(first.sessionId)!.isAudible, isFalse);
      expect(manager.session(second.sessionId)!.isAudible, isFalse);
      await manager.close();
    },
  );

  test(
    'seeking beyond 30 seconds does not create watched resume time',
    () async {
      final firstProgress = _Progress();
      final firstFactory = _TransportFactory();
      final firstManager = PlaybackManager(
        targetResolver: const _Resolver(),
        progressPort: firstProgress,
        transportFactory: firstFactory.create,
      );
      const movie = MoviePlaybackHandoff(
        sourceId: 'source',
        title: 'movie',
        providerItemId: 'movie',
        extension: 'mp4',
        libraryItemId: 'library',
      );
      final first = await firstManager.start(movie) as PlaybackStarted;
      await firstManager.seek(first.sessionId, const Duration(minutes: 2));
      firstFactory.created.single.emit(
        _ready(position: const Duration(minutes: 2)),
      );
      await firstManager.pause(first.sessionId);
      final checkpoint = firstProgress.saved.last;
      expect(checkpoint.position, const Duration(minutes: 2));
      expect(checkpoint.watched, Duration.zero);
      await firstManager.close();

      final secondFactory = _TransportFactory();
      final secondManager = PlaybackManager(
        targetResolver: const _Resolver(),
        progressPort: _Progress(loaded: checkpoint),
        transportFactory: secondFactory.create,
      );
      await secondManager.start(movie);
      expect(secondFactory.created.single.seeks, isEmpty);
      await secondManager.close();
    },
  );

  test('failed Start over seek preserves progress and position', () async {
    final progress = _Progress();
    final factory = _TransportFactory(
      specs: const [_TransportSpec(seekFails: true)],
    );
    final manager = PlaybackManager(
      targetResolver: const _Resolver(),
      progressPort: progress,
      transportFactory: factory.create,
    );
    const movie = MoviePlaybackHandoff(
      sourceId: 'source',
      title: 'movie',
      providerItemId: 'movie',
      extension: 'mp4',
      libraryItemId: 'library',
    );
    final started = await manager.start(movie) as PlaybackStarted;
    factory.created.single.emit(_ready(position: const Duration(seconds: 70)));

    final outcome = await manager.startOverWithOutcome(started.sessionId);

    expect(outcome.seekSucceeded, isFalse);
    expect(progress.cleared, 0);
    expect(
      manager.session(started.sessionId)!.transportState.position,
      const Duration(seconds: 70),
    );
    await manager.close();
  });
}

LivePlaybackHandoff _live(String sourceId, String title) => LivePlaybackHandoff(
  sourceId: sourceId,
  title: title,
  providerItemId: title,
  extension: 'ts',
);

PlaybackTransportState _ready({Duration position = Duration.zero}) =>
    PlaybackTransportState(
      hasVideo: true,
      isPlaying: true,
      position: position,
      duration: const Duration(minutes: 5),
    );

class _Resolver implements PlaybackTargetResolverPort {
  const _Resolver();

  @override
  Future<PlaybackResolvedTarget> resolve(PlaybackHandoff handoff) async =>
      PlaybackResolvedTarget(uri: Uri.parse('https://stream.example/video'));
}

class _NeverResolver implements PlaybackTargetResolverPort {
  const _NeverResolver();
  @override
  Future<PlaybackResolvedTarget> resolve(PlaybackHandoff handoff) =>
      Completer<PlaybackResolvedTarget>().future;
}

class _Admission implements PlaybackAdmissionPort {
  _Admission(this.values);

  final Map<String, int> values;

  @override
  Future<int> effectiveLimitForSource(String sourceId) async =>
      values[sourceId] ?? 1;
}

class _Progress implements PlaybackProgressPort {
  _Progress({this.loaded});

  final PlaybackCheckpoint? loaded;
  int loads = 0;
  int cleared = 0;
  final saved = <PlaybackCheckpoint>[];

  @override
  Future<bool> clear(PlaybackProgressIdentity identity) async {
    cleared += 1;
    return true;
  }

  @override
  Future<PlaybackCheckpoint?> load(PlaybackProgressIdentity identity) async {
    loads += 1;
    return loaded;
  }

  @override
  Future<bool> save(
    PlaybackProgressIdentity identity,
    PlaybackCheckpoint checkpoint,
  ) async {
    saved.add(checkpoint);
    return true;
  }
}

class _TransportSpec {
  const _TransportSpec({
    this.openFails = false,
    this.neverReady = false,
    this.withTracks = false,
    this.muteFailsAfterOpen = false,
    this.seekFails = false,
  });

  final bool openFails;
  final bool neverReady;
  final bool withTracks;
  final bool muteFailsAfterOpen;
  final bool seekFails;
}

class _TransportFactory {
  _TransportFactory({this.log, this.specs = const []});

  final List<String>? log;
  final List<_TransportSpec> specs;
  final created = <_FakeTransport>[];

  PlaybackTransport create() {
    final number = created.length + 1;
    final spec = number <= specs.length
        ? specs[number - 1]
        : const _TransportSpec();
    log?.add('create-$number');
    final transport = _FakeTransport(number, spec, log);
    created.add(transport);
    return transport;
  }
}

class _FakeTransport implements PlaybackTrackTransport {
  _FakeTransport(this.number, this.spec, this.log);

  final int number;
  final _TransportSpec spec;
  final List<String>? log;
  final _states = StreamController<PlaybackTransportState>.broadcast(
    sync: true,
  );
  final seeks = <Duration>[];
  final muteRequests = <bool>[];
  bool disposed = false;
  bool muted = false;
  bool opened = false;
  bool failUnmute = false;
  String? selectedAudio;
  String? selectedSubtitle;

  @override
  Stream<PlaybackTransportState> get states => _states.stream;

  void emit(PlaybackTransportState state) {
    if (!_states.isClosed) _states.add(state);
  }

  @override
  Widget buildVideo() => const SizedBox(key: ValueKey('fake-video'));

  @override
  Future<void> open(
    Uri uri, {
    Map<String, String> httpHeaders = const {},
  }) async {
    log?.add('open-$number');
    opened = true;
    if (spec.openFails) throw StateError('private transport failure');
    if (spec.neverReady) return;
    emit(
      PlaybackTransportState(
        hasVideo: true,
        isPlaying: true,
        duration: const Duration(minutes: 5),
        audioTracks: spec.withTracks
            ? const [
                PlaybackMediaTrack(id: 'audio-1', label: 'English'),
                PlaybackMediaTrack(id: 'audio-2', label: 'Spanish'),
              ]
            : const [],
        subtitleTracks: spec.withTracks
            ? const [PlaybackMediaTrack(id: 'sub-1', label: 'English')]
            : const [],
      ),
    );
  }

  @override
  Future<void> pause() async => log?.add('pause-$number');

  @override
  Future<void> play() async => log?.add('play-$number');

  @override
  Future<void> seek(Duration position) async {
    if (spec.seekFails) throw StateError('seek failed');
    seeks.add(position);
    log?.add('seek-$number');
  }

  @override
  Future<void> selectAudioTrack(String id) async {
    selectedAudio = id;
  }

  @override
  Future<void> selectSubtitleTrack(String id) async {
    selectedSubtitle = id;
  }

  @override
  Future<void> setMuted(bool value) async {
    muteRequests.add(value);
    if (opened && value && spec.muteFailsAfterOpen) {
      throw StateError('mute failed');
    }
    if (opened && !value && failUnmute) {
      throw StateError('unmute failed');
    }
    muted = value;
    log?.add('mute-$number-$value');
  }

  @override
  Future<void> setVolume(double volume) async => log?.add('volume-$number');

  @override
  Future<void> dispose() async {
    disposed = true;
    log?.add('dispose-$number');
  }
}
