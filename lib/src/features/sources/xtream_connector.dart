/// Redacted outcomes that presentation can safely show. Network and provider
/// details never cross the import worker boundary.
enum SourceImportFailureKind {
  authentication,
  unreachable,
  emptyResponse,
  tooLarge,
  timedOut,
  localPersistence,
  cancelled,
}

class SourceImportFailure implements Exception {
  const SourceImportFailure(this.kind);
  final SourceImportFailureKind kind;
}
