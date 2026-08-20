const epgMaximumProgramDuration = Duration(hours: 24);

enum EpgAvailability {
  unknown,
  refreshing,
  available,
  empty,
  temporarilyUnavailable,
  unsupported,
}

enum EpgRefreshFailure {
  credentialsUnavailable,
  authentication,
  unreachable,
  malformedResponse,
  responseTooLarge,
  timedOut,
  localPersistence,
  cancelled,
  unsupported,
}

/// One provider-owned programme attached to an exact local Live catalog row.
class EpgProgram {
  const EpgProgram({
    required this.catalogItemId,
    required this.startUtc,
    required this.endUtc,
    required this.title,
    this.description,
  });

  final String catalogItemId;
  final DateTime startUtc;
  final DateTime endUtc;
  final String title;
  final String? description;

  @override
  String toString() =>
      'EpgProgram(startUtc: ${startUtc.toUtc().toIso8601String()}, '
      'endUtc: ${endUtc.toUtc().toIso8601String()})';
}

class EpgNowNext {
  const EpgNowNext({required this.current, required this.next});

  final EpgProgram? current;
  final EpgProgram? next;
}

/// One bounded cached schedule window. Provider keys and credentials never
/// cross this presentation-facing model.
class EpgChannelWindow {
  const EpgChannelWindow({
    required this.catalogItemId,
    required this.availability,
    required this.programs,
    required this.nowNext,
  });

  final String catalogItemId;
  final EpgAvailability availability;
  final List<EpgProgram> programs;
  final EpgNowNext nowNext;
}

/// An internal exact Xtream request claim. Its string form is intentionally
/// redacted so provider identifiers cannot reach ordinary diagnostics.
class EpgRefreshTarget {
  const EpgRefreshTarget({
    required this.sourceId,
    required this.catalogItemId,
    required this.providerStreamId,
    required this.generation,
  });

  final String sourceId;
  final String catalogItemId;
  final String providerStreamId;
  final int generation;

  @override
  String toString() => 'EpgRefreshTarget(redacted)';
}

class EpgRefreshSummary {
  const EpgRefreshSummary({
    required this.claimed,
    required this.refreshed,
    required this.empty,
    required this.failed,
    required this.unsupported,
    this.failure,
  });

  const EpgRefreshSummary.none()
    : claimed = 0,
      refreshed = 0,
      empty = 0,
      failed = 0,
      unsupported = 0,
      failure = null;

  final int claimed;
  final int refreshed;
  final int empty;
  final int failed;
  final int unsupported;
  final EpgRefreshFailure? failure;

  @override
  String toString() =>
      'EpgRefreshSummary(claimed: $claimed, refreshed: $refreshed, '
      'empty: $empty, failed: $failed, unsupported: $unsupported, '
      'failure: ${failure?.name})';
}
