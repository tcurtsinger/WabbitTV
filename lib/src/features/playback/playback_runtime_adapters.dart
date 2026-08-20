import 'dart:async';

import '../browse/playback_handoff.dart';
import '../sources/credential_store.dart';
import '../sources/source_catalog_database.dart';
import '../sources/source_models.dart';
import 'playback_manager.dart';
import 'playback_transport.dart';

/// The app's direct, local bridge from persisted connection policy to the
/// manager's admission boundary.
class DatabasePlaybackAdmissionPort implements PlaybackAdmissionPort {
  const DatabasePlaybackAdmissionPort(this.database);

  final SourceCatalogDatabase database;

  @override
  Future<int> effectiveLimitForSource(String sourceId) async {
    final allowance = await database.loadSourceConnectionAllowance(sourceId);
    return allowance?.effectiveLimit ?? 1;
  }
}

/// Maps exact Movie/Episode progress between the manager and local SQLite.
/// The opaque media key never contains a locator or credential.
class DatabasePlaybackProgressPort implements PlaybackProgressPort {
  const DatabasePlaybackProgressPort(this.database);

  final SourceCatalogDatabase database;

  @override
  Future<PlaybackCheckpoint?> load(PlaybackProgressIdentity identity) async {
    final value = await database.loadPlaybackProgress(
      libraryItemId: identity.libraryItemId,
      mediaKey: identity.mediaKey,
    );
    if (value == null) return null;
    return PlaybackCheckpoint(
      position: Duration(milliseconds: value.positionMs),
      duration: Duration(milliseconds: value.durationMs),
      completed: value.completed,
      updatedAt: value.updatedAt,
      watched: Duration(milliseconds: value.watchedMs),
    );
  }

  @override
  Future<bool> save(
    PlaybackProgressIdentity identity,
    PlaybackCheckpoint checkpoint,
  ) => database.upsertPlaybackProgress(
    PlaybackProgress(
      libraryItemId: identity.libraryItemId,
      mediaKey: identity.mediaKey,
      positionMs: checkpoint.position.inMilliseconds,
      durationMs: checkpoint.duration.inMilliseconds,
      completed: checkpoint.completed,
      watchedMs: checkpoint.watched.inMilliseconds,
      updatedAt: checkpoint.updatedAt.toUtc(),
    ),
  );

  @override
  Future<bool> clear(PlaybackProgressIdentity identity) =>
      database.clearPlaybackProgress(
        libraryItemId: identity.libraryItemId,
        mediaKey: identity.mediaKey,
      );
}

/// Resolves the exact ready source, then reads its secret only for the native
/// open call. The returned target is redacted and must remain manager-local.
class SourcePlaybackTargetResolver implements PlaybackTargetResolverPort {
  const SourcePlaybackTargetResolver({
    required this.sourceResolver,
    required this.credentialStore,
  });

  factory SourcePlaybackTargetResolver.database({
    required SourceCatalogDatabase database,
    required CredentialStore credentialStore,
  }) => SourcePlaybackTargetResolver(
    sourceResolver: database.loadReadySourceById,
    credentialStore: credentialStore,
  );

  final FutureOr<PersistedSource?> Function(String sourceId) sourceResolver;
  final CredentialStore credentialStore;

  @override
  Future<PlaybackResolvedTarget> resolve(PlaybackHandoff handoff) async {
    PersistedSource? source;
    try {
      source = await sourceResolver(handoff.sourceId);
    } catch (_) {
      throw const PlaybackResolutionException(
        PlaybackSessionFailure.unavailable,
      );
    }
    if (source == null || source.id != handoff.sourceId) {
      throw const PlaybackResolutionException(
        PlaybackSessionFailure.unavailable,
      );
    }
    if (handoff is M3uLivePlaybackHandoff) {
      return PlaybackResolvedTarget(
        uri: handoff.uri,
        httpHeaders: handoff.httpHeaders,
      );
    }
    if (handoff is! XtreamPlaybackHandoff) {
      throw const PlaybackResolutionException(
        PlaybackSessionFailure.unavailable,
      );
    }

    StoredCredential? credential;
    try {
      credential = await credentialStore.read(source.credentialKey);
    } catch (_) {
      throw const PlaybackResolutionException(
        PlaybackSessionFailure.credentialsUnavailable,
      );
    }
    if (credential == null) {
      throw const PlaybackResolutionException(
        PlaybackSessionFailure.credentialsUnavailable,
      );
    }
    try {
      return PlaybackResolvedTarget(
        uri: resolveXtreamPlaybackUri(handoff: handoff, credential: credential),
      );
    } catch (_) {
      throw const PlaybackResolutionException(
        PlaybackSessionFailure.credentialsUnavailable,
      );
    }
  }
}

Uri resolveXtreamPlaybackUri({
  required XtreamPlaybackHandoff handoff,
  required StoredCredential credential,
}) {
  final server = credential.serverUrl?.trim();
  if (server == null || server.isEmpty) throw const FormatException();
  final endpoint = Uri.parse(
    server.contains('://') ? server : 'https://$server',
  );
  if ((endpoint.scheme != 'http' && endpoint.scheme != 'https') ||
      endpoint.host.isEmpty ||
      credential.username.trim().isEmpty ||
      credential.password.isEmpty) {
    throw const FormatException();
  }
  final mediaType = switch (handoff) {
    LivePlaybackHandoff() => 'live',
    MoviePlaybackHandoff() => 'movie',
    EpisodePlaybackHandoff() => 'series',
  };
  final extension = handoff.extension.trim().isEmpty
      ? (handoff is LivePlaybackHandoff ? 'ts' : 'mp4')
      : handoff.extension.trim();
  final baseSegments = endpoint.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (baseSegments.lastOrNull == 'player_api.php') baseSegments.removeLast();
  return endpoint.replace(
    pathSegments: [
      ...baseSegments,
      mediaType,
      credential.username,
      credential.password,
      '${handoff.providerItemId}.$extension',
    ],
    query: null,
    fragment: null,
  );
}

class PlaybackVariantCandidate {
  const PlaybackVariantCandidate({required this.label, required this.handoff});

  final String label;
  final PlaybackHandoff handoff;

  @override
  String toString() => 'PlaybackVariantCandidate(redacted)';
}

abstract interface class PlaybackExactVariantPort {
  Future<List<PlaybackVariantCandidate>> loadExactVariants(
    PlaybackHandoff current,
  );
}

/// Exact identity members only. No title, external-ID, or fuzzy search occurs.
class DatabasePlaybackExactVariantPort implements PlaybackExactVariantPort {
  const DatabasePlaybackExactVariantPort(this.database);

  final SourceCatalogDatabase database;

  @override
  Future<List<PlaybackVariantCandidate>> loadExactVariants(
    PlaybackHandoff current,
  ) async {
    final identity = current.libraryItemId;
    if (identity == null || identity.isEmpty) return const [];
    final members = await database.loadPlayableVariants(
      libraryItemId: identity,
    );
    final candidates = <PlaybackVariantCandidate>[];
    for (final member in members) {
      try {
        final handoff = playbackHandoffForLibrary(member);
        if (_samePlayable(current, handoff)) continue;
        candidates.add(
          PlaybackVariantCandidate(
            label: member.sourceDisplayName,
            handoff: handoff,
          ),
        );
      } catch (_) {
        // A malformed exact member is unavailable, not a reason to infer one.
      }
    }
    return List.unmodifiable(candidates);
  }
}

bool _samePlayable(PlaybackHandoff first, PlaybackHandoff second) {
  if (first.runtimeType != second.runtimeType ||
      first.sourceId != second.sourceId) {
    return false;
  }
  if (first is XtreamPlaybackHandoff && second is XtreamPlaybackHandoff) {
    return first.providerItemId == second.providerItemId &&
        first.extension == second.extension;
  }
  if (first is M3uLivePlaybackHandoff && second is M3uLivePlaybackHandoff) {
    return first.uri == second.uri;
  }
  return false;
}

PlaybackManager createProductionPlaybackManager({
  required SourceCatalogDatabase database,
  required CredentialStore credentialStore,
  PlaybackManagerTransportFactory? transportFactory,
  Duration startupDeadline = playbackStartupDeadline,
}) => PlaybackManager(
  targetResolver: SourcePlaybackTargetResolver.database(
    database: database,
    credentialStore: credentialStore,
  ),
  admissionPort: DatabasePlaybackAdmissionPort(database),
  progressPort: DatabasePlaybackProgressPort(database),
  transportFactory: transportFactory ?? MediaKitPlaybackTransport.create,
  startupDeadline: startupDeadline,
);
