import 'dart:convert';

import '../sources/source_models.dart';

/// A deliberately credential-free instruction for the future playback layer.
///
/// Provider item IDs are required to resolve a stream later, but never appear
/// in its diagnostic/string form.
sealed class PlaybackHandoff {
  const PlaybackHandoff({
    required this.sourceId,
    required this.title,
    required this.providerItemId,
    required this.extension,
  });

  final String sourceId;
  final String title;
  final String providerItemId;
  final String extension;

  @override
  String toString() => '$runtimeType(redacted)';
}

final class LivePlaybackHandoff extends PlaybackHandoff {
  const LivePlaybackHandoff({
    required super.sourceId,
    required super.title,
    required super.providerItemId,
    required super.extension,
  });
}

final class MoviePlaybackHandoff extends PlaybackHandoff {
  const MoviePlaybackHandoff({
    required super.sourceId,
    required super.title,
    required super.providerItemId,
    required super.extension,
  });
}

final class EpisodePlaybackHandoff extends PlaybackHandoff {
  const EpisodePlaybackHandoff({
    required super.sourceId,
    required super.title,
    required super.providerItemId,
    required super.extension,
  });
}

/// The opaque Xtream catalog reference after its minimal safe shape is known.
class SeriesReference {
  const SeriesReference(this.providerItemId);

  final String providerItemId;

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

PlaybackHandoff playbackHandoffFor(BrowseCatalogItem item) {
  final reference = _referenceFor(item);
  return switch (item.kind) {
    SourceMediaKind.live => LivePlaybackHandoff(
      sourceId: item.sourceId,
      title: item.title,
      providerItemId: reference.providerItemId,
      extension: reference.extension ?? 'ts',
    ),
    SourceMediaKind.movies => MoviePlaybackHandoff(
      sourceId: item.sourceId,
      title: item.title,
      providerItemId: reference.providerItemId,
      extension: reference.extension ?? 'mp4',
    ),
    SourceMediaKind.series => throw const ContinuationException(
      ContinuationFailure.invalidReference,
    ),
  };
}

SeriesReference seriesReferenceFor(BrowseCatalogItem item) {
  if (item.kind != SourceMediaKind.series) {
    throw const ContinuationException(ContinuationFailure.invalidReference);
  }
  return SeriesReference(_referenceFor(item).providerItemId);
}

class _ImportedReference {
  const _ImportedReference({required this.providerItemId, this.extension});

  final String providerItemId;
  final String? extension;
}

_ImportedReference _referenceFor(BrowseCatalogItem item) {
  try {
    final decoded = jsonDecode(item.playbackRef);
    if (decoded is! Map) throw const FormatException();
    final providerId = decoded['providerId'];
    final kind = decoded['kind'];
    final extension = decoded['extension'];
    if (providerId is! String ||
        providerId.trim().isEmpty ||
        kind != item.kind.name ||
        (extension != null &&
            (extension is! String || extension.trim().isEmpty))) {
      throw const FormatException();
    }
    return _ImportedReference(
      providerItemId: providerId,
      extension: extension as String?,
    );
  } catch (_) {
    throw const ContinuationException(ContinuationFailure.invalidReference);
  }
}
