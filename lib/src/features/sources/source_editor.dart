/// The three deliberately small source forms supported by the Source Ledger.
enum SourceEditorKind { xtream, m3uUrl, m3uFile }

extension SourceEditorKindLabels on SourceEditorKind {
  String get label => switch (this) {
    SourceEditorKind.xtream => 'Xtream',
    SourceEditorKind.m3uUrl => 'M3U URL',
    SourceEditorKind.m3uFile => 'Local M3U file',
  };

  String get databaseKind => switch (this) {
    SourceEditorKind.xtream => 'xtream',
    SourceEditorKind.m3uUrl => 'm3u_url',
    SourceEditorKind.m3uFile => 'm3u_file',
  };

  static SourceEditorKind fromDatabaseKind(String kind) => switch (kind) {
    'm3u_url' => SourceEditorKind.m3uUrl,
    'm3u_file' => SourceEditorKind.m3uFile,
    _ => SourceEditorKind.xtream,
  };
}

/// The public, credential-free identity needed to open an existing source.
/// The secret fields are loaded only by [SourceSetupController].
class SourceEditorRequest {
  const SourceEditorRequest({
    required this.sourceId,
    required this.sourceName,
    required this.databaseKind,
  });

  final String sourceId;
  final String sourceName;
  final String databaseKind;
}

/// A private, in-memory form snapshot. It must not be persisted or logged.
class SourceEditorDraft {
  const SourceEditorDraft({
    required this.sourceId,
    required this.credentialKey,
    required this.kind,
    required this.name,
    required this.endpoint,
    required this.username,
    required this.password,
  });

  final String sourceId;
  final String credentialKey;
  final SourceEditorKind kind;
  final String name;
  final String endpoint;
  final String username;
  final String password;
}

typedef M3uFilePicker = Future<String?> Function();
