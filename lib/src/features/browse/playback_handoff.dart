import 'dart:collection';
import 'dart:convert';

import '../sources/source_models.dart';

/// A deliberately credential-free instruction for the playback layer.
///
/// Provider item IDs and M3U locators are necessary only at the handoff
/// boundary. They never appear in diagnostic or string form.
sealed class PlaybackHandoff {
  const PlaybackHandoff({
    required this.sourceId,
    required this.title,
    this.libraryItemId,
  });

  final String sourceId;
  final String title;

  /// Present only when playback originated from a local library identity.
  /// Source credentials and final stream URLs never travel in this field.
  final String? libraryItemId;

  /// Legacy catalog code may inspect these after narrowing to an Xtream
  /// subtype. M3U deliberately exposes no provider identifier or extension.
  String get providerItemId => '';
  String get extension => '';

  PlaybackMediaKind get mediaKind;

  /// Stable resume identity for VOD imported into the local library.
  ///
  /// Episodes deliberately include the exact episode provider identity in
  /// [PlaybackProgressIdentity.mediaKey]; the parent series library identity
  /// alone is never used as an episode checkpoint key.
  PlaybackProgressIdentity? get progressIdentity => null;

  @override
  String toString() => '$runtimeType(redacted)';
}

enum PlaybackMediaKind { live, movie, episode }

class PlaybackProgressIdentity {
  const PlaybackProgressIdentity({
    required this.libraryItemId,
    required this.mediaKey,
  });

  final String libraryItemId;
  final String mediaKey;

  @override
  String toString() => 'PlaybackProgressIdentity(redacted)';
}

/// The common safe shape for an Xtream item which resolves just in time.
sealed class XtreamPlaybackHandoff extends PlaybackHandoff {
  const XtreamPlaybackHandoff({
    required super.sourceId,
    required super.title,
    required this.providerItemId,
    required this.extension,
    super.libraryItemId,
  });

  @override
  final String providerItemId;
  @override
  final String extension;
}

final class LivePlaybackHandoff extends XtreamPlaybackHandoff {
  const LivePlaybackHandoff({
    required super.sourceId,
    required super.title,
    required super.providerItemId,
    required super.extension,
    super.libraryItemId,
  });

  @override
  PlaybackMediaKind get mediaKind => PlaybackMediaKind.live;
}

final class MoviePlaybackHandoff extends XtreamPlaybackHandoff {
  const MoviePlaybackHandoff({
    required super.sourceId,
    required super.title,
    required super.providerItemId,
    required super.extension,
    super.libraryItemId,
  });

  @override
  PlaybackMediaKind get mediaKind => PlaybackMediaKind.movie;

  @override
  PlaybackProgressIdentity? get progressIdentity => _progressIdentity(
    libraryItemId: libraryItemId,
    sourceId: sourceId,
    kind: mediaKind,
    providerItemId: providerItemId,
  );
}

final class EpisodePlaybackHandoff extends XtreamPlaybackHandoff {
  const EpisodePlaybackHandoff({
    required super.sourceId,
    required super.title,
    required super.providerItemId,
    required super.extension,
    super.libraryItemId,
  });

  @override
  PlaybackMediaKind get mediaKind => PlaybackMediaKind.episode;

  @override
  PlaybackProgressIdentity? get progressIdentity => _progressIdentity(
    libraryItemId: libraryItemId,
    sourceId: sourceId,
    kind: mediaKind,
    providerItemId: providerItemId,
  );
}

/// A parsed M3U live locator plus its per-item HTTP headers.
///
/// Construction is private to this file so all values have passed the same
/// bounded parser before they reach a transport. The public map is immutable.
final class M3uLivePlaybackHandoff extends PlaybackHandoff {
  M3uLivePlaybackHandoff._({
    required super.sourceId,
    required super.title,
    required this.uri,
    required Map<String, String> httpHeaders,
    super.libraryItemId,
  }) : httpHeaders = UnmodifiableMapView(Map<String, String>.from(httpHeaders));

  final Uri uri;
  final Map<String, String> httpHeaders;

  @override
  PlaybackMediaKind get mediaKind => PlaybackMediaKind.live;
}

PlaybackProgressIdentity? _progressIdentity({
  required String? libraryItemId,
  required String sourceId,
  required PlaybackMediaKind kind,
  required String providerItemId,
}) {
  if (libraryItemId == null || libraryItemId.trim().isEmpty) return null;
  String part(String value) => '${value.length}:$value';
  return PlaybackProgressIdentity(
    libraryItemId: libraryItemId,
    mediaKey: switch (kind) {
      PlaybackMediaKind.movie => 'movie',
      PlaybackMediaKind.episode =>
        'v1|episode|${part(sourceId)}|${part(providerItemId)}',
      PlaybackMediaKind.live => throw StateError(
        'Live playback has no progress identity.',
      ),
    },
  );
}

/// The opaque Xtream catalog reference after its minimal safe shape is known.
class SeriesReference {
  const SeriesReference(this.providerItemId, {this.libraryItemId});

  final String providerItemId;
  final String? libraryItemId;

  @override
  String toString() => 'SeriesReference(redacted)';
}

class SeriesEpisode {
  const SeriesEpisode({
    required this.providerItemId,
    required this.title,
    required this.extension,
  });

  final String providerItemId;
  final String title;
  final String extension;

  @override
  String toString() => 'SeriesEpisode(redacted)';
}

class SeriesSeason {
  const SeriesSeason({required this.name, required this.episodes});

  final String name;
  final List<SeriesEpisode> episodes;
}

class SeriesInfo {
  const SeriesInfo({required this.seasons});

  final List<SeriesSeason> seasons;
}

enum ContinuationFailure {
  invalidReference,
  credentialsUnavailable,
  timedOut,
  unavailable,
  responseTooLarge,
  malformedResponse,
  cancelled,
}

extension ContinuationFailureCopy on ContinuationFailure {
  String get message => switch (this) {
    ContinuationFailure.invalidReference =>
      'This item cannot be opened from the imported catalog.',
    ContinuationFailure.credentialsUnavailable =>
      'This source needs its saved account details restored in Settings.',
    ContinuationFailure.timedOut => 'The series details took too long to load.',
    ContinuationFailure.unavailable =>
      'Series details are unavailable right now.',
    ContinuationFailure.responseTooLarge =>
      'Series details were larger than this step can safely load.',
    ContinuationFailure.malformedResponse =>
      'Series details could not be read from this source.',
    ContinuationFailure.cancelled => 'Series details were cancelled.',
  };
}

class ContinuationException implements Exception {
  const ContinuationException(this.failure);

  final ContinuationFailure failure;

  @override
  String toString() => 'ContinuationException(redacted)';
}

PlaybackHandoff playbackHandoffFor(BrowseCatalogItem item) =>
    _playbackHandoffFor(
      sourceId: item.sourceId,
      title: item.title,
      kind: item.kind,
      playbackRef: item.playbackRef,
      libraryItemId: item.libraryItemId,
    );

/// Builds the same safe playback instruction for a merged library result.
///
/// The chosen library variant's [LibraryCatalogItem.sourceId] remains the
/// handoff source; it is never inferred from the shell's currently open view.
PlaybackHandoff playbackHandoffForLibrary(LibraryCatalogItem item) =>
    _playbackHandoffFor(
      sourceId: item.sourceId,
      title: item.title,
      kind: item.kind,
      playbackRef: item.playbackRef,
      libraryItemId: item.libraryItemId,
    );

PlaybackHandoff _playbackHandoffFor({
  required String sourceId,
  required String title,
  required SourceMediaKind kind,
  required String playbackRef,
  required String? libraryItemId,
}) {
  if (kind == SourceMediaKind.series) {
    throw const ContinuationException(ContinuationFailure.invalidReference);
  }
  final decoded = _decodedReference(playbackRef);
  if (decoded.containsKey('url')) {
    if (kind != SourceMediaKind.live) {
      throw const ContinuationException(ContinuationFailure.invalidReference);
    }
    return _m3uHandoff(
      sourceId: sourceId,
      title: title,
      decoded: decoded,
      libraryItemId: libraryItemId,
    );
  }
  final reference = _xtreamReference(kind: kind, decoded: decoded);
  return switch (kind) {
    SourceMediaKind.live => LivePlaybackHandoff(
      sourceId: sourceId,
      title: title,
      providerItemId: reference.providerItemId,
      extension: reference.extension ?? 'ts',
      libraryItemId: libraryItemId,
    ),
    SourceMediaKind.movies => MoviePlaybackHandoff(
      sourceId: sourceId,
      title: title,
      providerItemId: reference.providerItemId,
      extension: reference.extension ?? 'mp4',
      libraryItemId: libraryItemId,
    ),
    SourceMediaKind.series => throw const ContinuationException(
      ContinuationFailure.invalidReference,
    ),
  };
}

SeriesReference seriesReferenceFor(BrowseCatalogItem item) =>
    _seriesReferenceFor(
      kind: item.kind,
      playbackRef: item.playbackRef,
      libraryItemId: item.libraryItemId,
    );

SeriesReference seriesReferenceForLibrary(LibraryCatalogItem item) =>
    _seriesReferenceFor(
      kind: item.kind,
      playbackRef: item.playbackRef,
      libraryItemId: item.libraryItemId,
    );

SeriesReference _seriesReferenceFor({
  required SourceMediaKind kind,
  required String playbackRef,
  required String? libraryItemId,
}) {
  if (kind != SourceMediaKind.series) {
    throw const ContinuationException(ContinuationFailure.invalidReference);
  }
  return SeriesReference(
    _xtreamReference(
      kind: kind,
      decoded: _decodedReference(playbackRef),
    ).providerItemId,
    libraryItemId: libraryItemId,
  );
}

Map<String, Object?> _decodedReference(String playbackRef) {
  try {
    final decoded = jsonDecode(playbackRef);
    if (decoded is! Map) throw const FormatException();
    return decoded.cast<String, Object?>();
  } catch (_) {
    throw const ContinuationException(ContinuationFailure.invalidReference);
  }
}

class _ImportedReference {
  const _ImportedReference({required this.providerItemId, this.extension});

  final String providerItemId;
  final String? extension;
}

_ImportedReference _xtreamReference({
  required SourceMediaKind kind,
  required Map<String, Object?> decoded,
}) {
  final providerId = decoded['providerId'];
  final importedKind = decoded['kind'];
  final extension = decoded['extension'];
  if (providerId is! String ||
      providerId.trim().isEmpty ||
      importedKind != kind.name ||
      (extension != null &&
          (extension is! String || extension.trim().isEmpty))) {
    throw const ContinuationException(ContinuationFailure.invalidReference);
  }
  return _ImportedReference(
    providerItemId: providerId,
    extension: extension as String?,
  );
}

const _maxM3uHeaders = 32;
const _maxM3uHeaderNameLength = 128;
const _maxM3uHeaderValueLength = 4096;
const _maxM3uHeaderBytes = 16 * 1024;
final _safeHeaderName = RegExp(r'^[A-Za-z0-9-]+$');

M3uLivePlaybackHandoff _m3uHandoff({
  required String sourceId,
  required String title,
  required Map<String, Object?> decoded,
  required String? libraryItemId,
}) {
  final rawUrl = decoded['url'];
  final uri = rawUrl is String ? Uri.tryParse(rawUrl.trim()) : null;
  if (uri == null || !uri.hasScheme || uri.scheme == 'file') {
    throw const ContinuationException(ContinuationFailure.invalidReference);
  }
  final rawHeaders = decoded['headers'];
  if (rawHeaders != null && rawHeaders is! Map) {
    throw const ContinuationException(ContinuationFailure.invalidReference);
  }
  final headers = <String, String>{};
  var bytes = 0;
  if (rawHeaders != null) {
    final headerMap = rawHeaders as Map;
    if (headerMap.length > _maxM3uHeaders) {
      throw const ContinuationException(ContinuationFailure.invalidReference);
    }
    for (final entry in headerMap.entries) {
      final name = entry.key;
      final value = entry.value;
      if (name is! String ||
          value is! String ||
          name.isEmpty ||
          name.length > _maxM3uHeaderNameLength ||
          value.isEmpty ||
          value.length > _maxM3uHeaderValueLength ||
          !_safeHeaderName.hasMatch(name)) {
        throw const ContinuationException(ContinuationFailure.invalidReference);
      }
      final typedName = name;
      final typedValue = value;
      bytes += typedName.length + typedValue.length;
      if (bytes > _maxM3uHeaderBytes) {
        throw const ContinuationException(ContinuationFailure.invalidReference);
      }
      headers[typedName] = typedValue;
    }
  }
  return M3uLivePlaybackHandoff._(
    sourceId: sourceId,
    title: title,
    uri: uri,
    httpHeaders: headers,
    libraryItemId: libraryItemId,
  );
}
