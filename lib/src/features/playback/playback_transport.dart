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
  });

  final bool isPlaying;
  final bool isBuffering;
  final bool hasVideo;
  final Duration position;
  final Duration duration;
  final double volume;
  final bool muted;
  final bool hasError;
}

class MediaKitPlaybackTransport implements PlaybackTransport {
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
  Future<void> dispose() => _player.dispose();
}
