import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// A deliberately small boundary around the native player.  It gives the UI a
/// deterministic test seam without introducing a second playback architecture.
abstract interface class PlaybackTransport {
  Stream<PlaybackTransportState> get states;
  Widget buildVideo();
  Future<void> open(Uri uri, {Map<String, String> httpHeaders = const {}});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setMuted(bool muted);
  Future<void> dispose();
}

/// Optional transport capability used by the Phase 5 Tracks ledger.
///
/// Keeping this separate from [PlaybackTransport] preserves the small player
/// seam used by older fixtures while allowing the shell-lifetime playback
/// manager to expose media-kit-free track values.
abstract interface class PlaybackTrackTransport implements PlaybackTransport {
  Future<void> selectAudioTrack(String id);
  Future<void> selectSubtitleTrack(String id);
}

/// A safe track value for presentation. Engine objects never leave the
/// transport boundary and the string form deliberately omits provider data.
class PlaybackMediaTrack {
  const PlaybackMediaTrack({
    required this.id,
    required this.label,
    this.language,
    this.isDefault = false,
  });

  final String id;
  final String label;
  final String? language;
  final bool isDefault;

  @override
  String toString() => 'PlaybackMediaTrack(redacted)';
}

class PlaybackTransportState {
  const PlaybackTransportState({
    this.isPlaying = false,
    this.isBuffering = false,
    this.hasVideo = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume = 100,
    this.muted = false,
    this.hasError = false,
    this.audioTracks = const [],
    this.subtitleTracks = const [],
    this.selectedAudioTrackId,
    this.selectedSubtitleTrackId,
  });

  final bool isPlaying;
  final bool isBuffering;
  final bool hasVideo;
  final Duration position;
  final Duration duration;
  final double volume;
  final bool muted;
  final bool hasError;
  final List<PlaybackMediaTrack> audioTracks;
  final List<PlaybackMediaTrack> subtitleTracks;
  final String? selectedAudioTrackId;
  final String? selectedSubtitleTrackId;

  PlaybackTransportState copyWith({
    bool? isPlaying,
    bool? isBuffering,
    bool? hasVideo,
    Duration? position,
    Duration? duration,
    double? volume,
    bool? muted,
    bool? hasError,
    List<PlaybackMediaTrack>? audioTracks,
    List<PlaybackMediaTrack>? subtitleTracks,
    String? selectedAudioTrackId,
    String? selectedSubtitleTrackId,
  }) => PlaybackTransportState(
    isPlaying: isPlaying ?? this.isPlaying,
    isBuffering: isBuffering ?? this.isBuffering,
    hasVideo: hasVideo ?? this.hasVideo,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
    hasError: hasError ?? this.hasError,
    audioTracks: audioTracks ?? this.audioTracks,
    subtitleTracks: subtitleTracks ?? this.subtitleTracks,
    selectedAudioTrackId: selectedAudioTrackId ?? this.selectedAudioTrackId,
    selectedSubtitleTrackId:
        selectedSubtitleTrackId ?? this.selectedSubtitleTrackId,
  );

  @override
  String toString() => 'PlaybackTransportState(redacted)';
}

class MediaKitPlaybackTransport implements PlaybackTrackTransport {
  MediaKitPlaybackTransport._(this._player, this._controller);

  factory MediaKitPlaybackTransport.create() {
    final player = Player(
      configuration: const PlayerConfiguration(
        logLevel: MPVLogLevel.error,
        title: 'Wabbit TV',
      ),
    );
    return MediaKitPlaybackTransport._(player, VideoController(player));
  }

  final Player _player;
  final VideoController _controller;
  double? _volumeBeforeMute;

  @override
  Stream<PlaybackTransportState> get states async* {
    var playing = _player.state.playing;
    var buffering = _player.state.buffering;
    var width = _player.state.width;
    var height = _player.state.height;
    var position = _player.state.position;
    var duration = _player.state.duration;
    var volume = _player.state.volume;
    var muted = _player.state.volume == 0;
    var tracks = _player.state.tracks;
    var selectedTrack = _player.state.track;
    var errored = false;
    final controller = StreamController<PlaybackTransportState>();
    void emit() => controller.add(
      PlaybackTransportState(
        isPlaying: playing,
        isBuffering: buffering,
        hasVideo: (width ?? 0) > 0 && (height ?? 0) > 0,
        position: position,
        duration: duration,
        volume: volume,
        muted: muted,
        hasError: errored,
        audioTracks: tracks.audio.map(_safeTrack).toList(growable: false),
        subtitleTracks: tracks.subtitle.map(_safeTrack).toList(growable: false),
        selectedAudioTrackId: selectedTrack.audio.id,
        selectedSubtitleTrackId: selectedTrack.subtitle.id,
      ),
    );
    final subscriptions = <StreamSubscription<dynamic>>[
      _player.stream.playing.listen((value) {
        playing = value;
        emit();
      }),
      _player.stream.buffering.listen((value) {
        buffering = value;
        emit();
      }),
      _player.stream.width.listen((value) {
        width = value;
        emit();
      }),
      _player.stream.height.listen((value) {
        height = value;
        emit();
      }),
      _player.stream.position.listen((value) {
        position = value;
        emit();
      }),
      _player.stream.duration.listen((value) {
        duration = value;
        emit();
      }),
      _player.stream.volume.listen((value) {
        volume = value;
        muted = value == 0;
        emit();
      }),
      _player.stream.tracks.listen((value) {
        tracks = value;
        emit();
      }),
      _player.stream.track.listen((value) {
        selectedTrack = value;
        emit();
      }),
      _player.stream.error.listen((_) {
        errored = true;
        emit();
      }),
    ];
    emit();
    try {
      yield* controller.stream;
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await controller.close();
    }
  }

  @override
  Widget buildVideo() => Video(
    controller: _controller,
    controls: NoVideoControls,
    fit: BoxFit.contain,
  );

  @override
  Future<void> open(Uri uri, {Map<String, String> httpHeaders = const {}}) =>
      _player.open(Media(uri.toString(), httpHeaders: httpHeaders), play: true);

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setMuted(bool muted) async {
    if (muted) {
      if (_player.state.volume > 0) _volumeBeforeMute = _player.state.volume;
      await _player.setVolume(0);
      return;
    }
    final restored = _volumeBeforeMute ?? _player.state.volume;
    _volumeBeforeMute = null;
    await _player.setVolume(restored > 0 ? restored : 100);
  }

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume(volume.clamp(0, 100));

  @override
  Future<void> selectAudioTrack(String id) async {
    if (id == 'auto') {
      await _player.setAudioTrack(AudioTrack.auto());
      return;
    }
    final track = _player.state.tracks.audio
        .where((candidate) => candidate.id == id)
        .firstOrNull;
    if (track == null) return;
    await _player.setAudioTrack(track);
  }

  @override
  Future<void> selectSubtitleTrack(String id) async {
    if (id == 'no') {
      await _player.setSubtitleTrack(SubtitleTrack.no());
      return;
    }
    if (id == 'auto') {
      await _player.setSubtitleTrack(SubtitleTrack.auto());
      return;
    }
    final track = _player.state.tracks.subtitle
        .where((candidate) => candidate.id == id)
        .firstOrNull;
    if (track == null) return;
    await _player.setSubtitleTrack(track);
  }

  @override
  Future<void> dispose() => _player.dispose();
}

PlaybackMediaTrack _safeTrack(dynamic track) {
  final id = track.id as String;
  final language = _safeTrackText(track.language as String?);
  final title = _safeTrackText(track.title as String?);
  final fallback = switch (id) {
    'auto' => 'Automatic',
    'no' => 'Off',
    _ => language ?? 'Track',
  };
  return PlaybackMediaTrack(
    id: id,
    label: title ?? fallback,
    language: language,
    isDefault: track.isDefault == true,
  );
}

String? _safeTrackText(String? value) {
  final normalized = value?.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();
  if (normalized == null || normalized.isEmpty) return null;
  return normalized.length <= 128 ? normalized : normalized.substring(0, 128);
}
