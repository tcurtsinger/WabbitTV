enum ProbeMediaKind { live, movie, episode }

extension ProbeMediaKindLabel on ProbeMediaKind {
  String get label => switch (this) {
    ProbeMediaKind.live => 'Live',
    ProbeMediaKind.movie => 'Movie',
    ProbeMediaKind.episode => 'Episode',
  };

  String get pathSegment => switch (this) {
    ProbeMediaKind.live => 'live',
    ProbeMediaKind.movie => 'movie',
    ProbeMediaKind.episode => 'series',
  };
}

enum ProbeFailure {
  authentication,
  accountInfoTimeout,
  accountResponseTooLarge,
  discoveryTimeout,
  discoveryResponseTooLarge,
  streamTimeout,
  noVideoTrack,
  screenshotUnavailable,
  playerError,
  buildOrPluginFailure,
}

extension ProbeFailureLabel on ProbeFailure {
  String get label => switch (this) {
    ProbeFailure.authentication => 'Authentication was not confirmed',
    ProbeFailure.accountInfoTimeout => 'Account check timed out',
    ProbeFailure.accountResponseTooLarge =>
      'Account response exceeded the 1 MiB probe limit',
    ProbeFailure.discoveryTimeout => 'Discovery timed out',
    ProbeFailure.discoveryResponseTooLarge =>
      'Discovery response exceeded the 64 MiB probe limit',
    ProbeFailure.streamTimeout => 'Stream did not start in time',
    ProbeFailure.noVideoTrack => 'No video track was detected',
    ProbeFailure.screenshotUnavailable => 'A video frame could not be captured',
    ProbeFailure.playerError => 'Player reported a playback error',
    ProbeFailure.buildOrPluginFailure =>
      'The Windows player bundle was unavailable',
  };
}

String discoveryProgressLabel(ProbeMediaKind kind, int step) {
  final mediaKind = kind == ProbeMediaKind.episode
      ? 'series'
      : kind.label.toLowerCase();
  return 'Loading $mediaKind candidates ($step of 3)';
}

String discoveryFailureLabel(ProbeMediaKind kind, ProbeFailure failure) {
  final mediaKind = kind == ProbeMediaKind.episode ? 'Series' : kind.label;
  return '$mediaKind candidates: ${failure.label}';
}

String categoryDiscoveryProgressLabel(ProbeMediaKind kind, int step) {
  final mediaKind = kind == ProbeMediaKind.episode
      ? 'series'
      : kind.label.toLowerCase();
  return 'Loading $mediaKind categories ($step of 3)';
}

String categoryDiscoveryFailureLabel(
  ProbeMediaKind kind,
  ProbeFailure failure,
) {
  final mediaKind = kind == ProbeMediaKind.episode ? 'Series' : kind.label;
  return '$mediaKind categories: ${failure.label}';
}

String categoryCandidateProgressLabel(ProbeMediaKind kind) {
  final mediaKind = kind == ProbeMediaKind.episode
      ? 'series'
      : kind.label.toLowerCase();
  return 'Loading $mediaKind candidates for the selected category';
}

String categoryCandidateFailureLabel(
  ProbeMediaKind kind,
  ProbeFailure failure,
) {
  final mediaKind = kind == ProbeMediaKind.episode ? 'Series' : kind.label;
  return '$mediaKind category candidates: ${failure.label}';
}

/// Intentionally memory-only. Never add fields to diagnostics, evidence, or
/// object stringification.
class StrongProbeCredentials {
  const StrongProbeCredentials({
    required this.endpoint,
    required this.username,
    required this.password,
  });

  final String endpoint;
  final String username;
  final String password;

  @override
  String toString() => 'StrongProbeCredentials(redacted)';
}

class StrongAccountFacts {
  const StrongAccountFacts({
    required this.authenticated,
    required this.status,
    required this.maxConnections,
    required this.activeConnections,
  });

  final bool authenticated;
  final String status;
  final int? maxConnections;
  final int? activeConnections;

  int? get availableConnections {
    final max = maxConnections;
    final active = activeConnections;
    if (max == null || active == null) return null;
    return max - active;
  }

  bool get permitsTwoStreams => (availableConnections ?? 0) >= 2;

  /// Unknown provider fields stay conservative but usable for one explicit,
  /// sequential probe. Known zero availability blocks even that one stream.
  bool get permitsSingleStream {
    if (maxConnections == null || activeConnections == null) return true;
    return availableConnections! >= 1;
  }

  @override
  String toString() =>
      'StrongAccountFacts('
      'authenticated: $authenticated, '
      'status: $status, '
      'maxConnections: $maxConnections, '
      'activeConnections: $activeConnections)';
}

/// Provider category identifiers and names are allowed only in the in-memory
/// category picker. Its string form deliberately reveals nothing.
class ProbeCategory {
  const ProbeCategory({
    required this.kind,
    required this.id,
    required this.name,
  });

  final ProbeMediaKind kind;
  final String id;
  final String name;

  @override
  String toString() => 'ProbeCategory(redacted)';
}

/// Provider identifiers and titles are allowed only in the in-memory picker
/// and playback session. Its string form deliberately reveals nothing.
class ProbeStreamCandidate {
  const ProbeStreamCandidate({
    required this.kind,
    required this.id,
    required this.title,
    required this.extension,
  });

  final ProbeMediaKind kind;
  final String id;
  final String title;
  final String extension;

  @override
  String toString() => 'ProbeStreamCandidate(redacted)';
}

class ProbeEvidence {
  const ProbeEvidence({
    required this.kind,
    required this.passed,
    required this.failure,
    required this.startupMs,
    required this.width,
    required this.height,
    required this.screenshotPresent,
  });

  final ProbeMediaKind kind;
  final bool passed;
  final ProbeFailure? failure;
  final int? startupMs;
  final int? width;
  final int? height;
  final bool screenshotPresent;

  String toSanitizedText() {
    final result = passed ? 'PASS' : (failure?.name ?? 'unknown');
    final dimensions = width == null || height == null
        ? 'n/a'
        : '${width}x$height';
    final startup = startupMs == null ? 'n/a' : '${startupMs}ms';
    return '${kind.label}: $result | startup $startup | video $dimensions '
        '| screenshot ${screenshotPresent ? 'present' : 'absent'}';
  }

  @override
  String toString() => toSanitizedText();
}

class TwoStreamEvidence {
  const TwoStreamEvidence({required this.attempted, required this.passed});

  final bool attempted;
  final bool? passed;

  String get label {
    if (!attempted) return 'Skipped';
    return passed == true ? 'Passed' : 'Failed';
  }
}

class ProbeRequestException implements Exception {
  const ProbeRequestException(this.failure);

  final ProbeFailure failure;

  @override
  String toString() => 'ProbeRequestException(${failure.name})';
}
