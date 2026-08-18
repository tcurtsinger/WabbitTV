import 'dart:async';

import 'package:flutter/foundation.dart';

import 'credential_store.dart';
import 'source_catalog_database.dart';
import 'source_editor.dart';
import 'source_models.dart';
import 'xtream_connector.dart';

enum ImportStageStatus { waiting, importing, complete, error }

/// Test seam only. The production path is InitialSourceImport, which keeps the
/// complete fetch/decode/write sequence in one cancellable worker.
abstract interface class SourceSetupPort {
  Future<ImportedStage> fetch(SourceDefinition source, SourceMediaKind kind);
  Future<SourceReady> commit(
    SourceDefinition source,
    List<ImportedStage> stages,
  );
  Future<void> remove(String sourceId);
}

class SourceSetupService {
  SourceSetupService({
    SourceCatalogDatabase? database,
    this.removeSourceForTest,
  }) : _database = database ?? const SourceCatalogDatabase();
  final SourceCatalogDatabase _database;
  final Future<void> Function(String sourceId)? removeSourceForTest;

  Future<InitialSourceImport> begin(SourceDefinition source) =>
      _database.beginInitialImport(source);
  Future<InitialSourceImport> beginM3u(M3uSourceInput source) =>
      _database.beginM3uInitialImport(source);
  Future<M3uRefreshImport> beginM3uRefresh({
    required String sourceId,
    required String locator,
    required bool isUrl,
  }) => _database.beginM3uRefresh(
    sourceId: sourceId,
    locator: locator,
    isUrl: isUrl,
  );
  Future<M3uRefreshImport> beginXtreamRefresh({
    required String sourceId,
    required StoredCredential credential,
  }) => _database.beginXtreamRefresh(
    sourceId: sourceId,
    serverUrl: credential.serverUrl ?? '',
    username: credential.username,
    password: credential.password,
  );
  Future<SourceOperationRecord?> sourceOperation(String sourceId) =>
      _database.loadSourceOperation(sourceId);
  Future<void> removeSource(String sourceId) =>
      removeSourceForTest?.call(sourceId) ?? _database.removeSource(sourceId);
  Future<void> setEnabled(String sourceId, bool enabled) =>
      _database.setSourceEnabled(sourceId, enabled);
  Future<void> recoverPending(CredentialStore credentials) =>
      _database.recoverPending(credentials);
  Future<PersistedSource?> loadReady() => _database.loadReadySource();
  Future<List<SourceRosterEntry>> loadSourceRoster() =>
      _database.loadSourceRoster();
  Future<void> renameSource(String sourceId, String name) =>
      _database.renameSource(sourceId, name);
}

class SourceSetupController extends ChangeNotifier {
  SourceSetupController({
    SourceSetupPort? service,
    SourceSetupService? productionService,
    CredentialStore? credentialStore,
  }) : assert(service == null || productionService == null),
       _testService = service,
       _service = service == null
           ? (productionService ?? SourceSetupService())
           : null,
       _credentialStore = credentialStore ?? SecureCredentialStore();

  final SourceSetupPort? _testService;
  final SourceSetupService? _service;
  final CredentialStore _credentialStore;
  final Map<SourceMediaKind, ImportStageStatus> _stages = {
    for (final kind in SourceMediaKind.values) kind: ImportStageStatus.waiting,
  };

  Map<String, String> fieldErrors = const {};
  SourceImportFailureKind? failure;
  SourceReady? ready;
  PersistedSource? persisted;
  bool isImporting = false;
  bool isCancelling = false;
  InitialSourceImport? _import;
  M3uRefreshImport? _m3uRefresh;
  Future<InitialSourceImport>? _beginning;
  bool _disposed = false;
  int _operation = 0;

  Map<SourceMediaKind, ImportStageStatus> get stages =>
      Map.unmodifiable(_stages);
  bool get busy => isImporting || isCancelling;

  /// Shell startup calls this once. A pending DB row cannot survive a crashed
  /// first import, and a ready row drives the production Home state.
  Future<void> initialize() async {
    if (_service == null) return;
    await _service.recoverPending(_credentialStore);
    persisted = await _service.loadReady();
    ready = persisted?.ready;
    if (!_disposed) notifyListeners();
  }

  Future<void> connect({
    required String name,
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    if (busy) return;
    final operation = ++_operation;
    final normalized = _validate(
      name: name,
      serverUrl: serverUrl,
      username: username,
      password: password,
    );
    if (normalized.errors.isNotEmpty) {
      fieldErrors = normalized.errors;
      failure = null;
      ready = null;
      _notify();
      return;
    }
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final source = SourceDefinition(
      id: 'source-$stamp',
      name: normalized.name!,
      serverUrl: normalized.serverUrl!,
      username: normalized.username!,
      password: password,
      credentialKey: 'wabbit-tv:$stamp',
    );
    fieldErrors = const {};
    failure = null;
    ready = null;
    isImporting = true;
    isCancelling = false;
    _resetStages();
    _notify();
    if (_service == null) {
      await _connectTestSeam(source, password, operation);
    } else {
      await _connectWorker(source, password);
    }
  }

  Future<void> connectM3uUrl({required String name, required String url}) =>
      _connectM3u(name: name, locator: url, kind: M3uSourceKind.m3uUrl);

  Future<void> connectM3uFile({required String name, required String path}) =>
      _connectM3u(name: name, locator: path, kind: M3uSourceKind.m3uFile);

  Future<void> _connectM3u({
    required String name,
    required String locator,
    required M3uSourceKind kind,
  }) async {
    if (busy || _service == null) return;
    final trimmedName = name.trim();
    final trimmedLocator = locator.trim();
    final validUrl =
        kind == M3uSourceKind.m3uUrl &&
        (Uri.tryParse(trimmedLocator)?.hasScheme ?? false) &&
        (Uri.tryParse(trimmedLocator)?.host.isNotEmpty ?? false);
    if (trimmedName.isEmpty ||
        trimmedLocator.isEmpty ||
        (kind == M3uSourceKind.m3uUrl && !validUrl)) {
      fieldErrors = {'source': 'Enter a valid source and playlist location.'};
      _notify();
      return;
    }
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final display = kind == M3uSourceKind.m3uUrl
        ? Uri.parse(trimmedLocator).host
        : trimmedLocator.split(RegExp(r'[\\/]')).last;
    final source = M3uSourceInput(
      id: 'source-$stamp',
      name: trimmedName,
      kind: kind,
      locator: trimmedLocator,
      credentialKey: 'wabbit-tv:$stamp',
      displayEndpoint: display,
    );
    fieldErrors = const {};
    failure = null;
    ready = null;
    isImporting = true;
    isCancelling = false;
    _resetStages();
    _notify();
    try {
      final import = await _service.beginM3u(source);
      _import = import;
      await import.pending;
      await _credentialStore.write(
        key: source.credentialKey,
        username: '',
        password: '',
        serverUrl: source.locator,
      );
      final result = await import.activate();
      ready = result;
      persisted = PersistedSource(
        id: source.id,
        name: source.name,
        credentialKey: source.credentialKey,
        counts: result.counts,
      );
    } on SourceImportFailure catch (error) {
      failure = error.kind == SourceImportFailureKind.cancelled
          ? null
          : error.kind;
      _markCurrentStageError();
      final import = _import;
      if (import != null) {
        await _cleanupNonReady(import, source.credentialKey, true);
      }
    } catch (_) {
      failure = SourceImportFailureKind.emptyResponse;
      final import = _import;
      if (import != null) {
        await _cleanupNonReady(import, source.credentialKey, true);
      }
    } finally {
      isImporting = false;
      _import = null;
      _notify();
    }
  }

  Future<void> _connectWorker(SourceDefinition source, String password) async {
    InitialSourceImport? import;
    var credentialMayExist = false;
    try {
      final beginning = _service!.begin(source);
      _beginning = beginning;
      import = await beginning;
      _beginning = null;
      _import = import;
      if (isCancelling || _disposed) {
        await import.cancel();
        return;
      }
      final subscription = import.events.listen((event) {
        if (event.kind != ImportWorkerEventKind.stage ||
            event.mediaKind == null) {
          return;
        }
        final kind = event.mediaKind!;
        _stages[kind] = event.count == null
            ? ImportStageStatus.importing
            : ImportStageStatus.complete;
        _notify();
      });
      try {
        await import.pending;
        if (isCancelling) {
          await _cleanupNonReady(
            import,
            source.credentialKey,
            credentialMayExist,
          );
          return;
        }
        // Credentials cross this phase boundary only after all catalog stages
        // committed pending. The endpoint also stays in OS-backed storage.
        credentialMayExist = true;
        await _credentialStore.write(
          key: source.credentialKey,
          username: source.username,
          password: password,
          serverUrl: source.serverUrl,
        );
        if (isCancelling) {
          await _cleanupNonReady(
            import,
            source.credentialKey,
            credentialMayExist,
          );
          return;
        }
        final sourceReady = await import.activate();
        ready = sourceReady;
        persisted = PersistedSource(
          id: source.id,
          name: source.name,
          credentialKey: source.credentialKey,
          counts: sourceReady.counts,
        );
        isImporting = false;
        _import = null;
        _notify();
      } on SourceImportFailure catch (error) {
        await _cleanupNonReady(
          import,
          source.credentialKey,
          credentialMayExist,
        );
        if (!isCancelling) {
          _markCurrentStageError();
          failure = error.kind == SourceImportFailureKind.cancelled
              ? null
              : error.kind;
        }
        isImporting = false;
        _import = null;
        _notify();
      } catch (_) {
        await _cleanupNonReady(
          import,
          source.credentialKey,
          credentialMayExist,
        );
        if (!isCancelling) {
          _markCurrentStageError();
          failure = SourceImportFailureKind.emptyResponse;
        }
        isImporting = false;
        _import = null;
        _notify();
      } finally {
        await subscription.cancel();
      }
    } catch (_) {
      if (import != null) {
        await _cleanupNonReady(
          import,
          source.credentialKey,
          credentialMayExist,
        );
      }
      if (!isCancelling) {
        _markCurrentStageError();
        failure = SourceImportFailureKind.unreachable;
      }
      isImporting = false;
      _notify();
    }
  }

  Future<void> _cleanupNonReady(
    InitialSourceImport import,
    String credentialKey,
    bool credentialMayExist,
  ) async {
    if (credentialMayExist) {
      try {
        await _credentialStore.delete(credentialKey);
      } catch (_) {}
    }
    try {
      await import.cleanup();
    } catch (_) {}
  }

  Future<void> _connectTestSeam(
    SourceDefinition source,
    String password,
    int operation,
  ) async {
    final service = _testService!;
    final imports = <ImportedStage>[];
    var credentialMayExist = false;
    try {
      for (final kind in SourceMediaKind.values) {
        _stages[kind] = ImportStageStatus.importing;
        _notify();
        final stage = await service.fetch(source, kind);
        if (isCancelling || operation != _operation) {
          await service.remove(source.id);
          return;
        }
        imports.add(stage);
        _stages[kind] = ImportStageStatus.complete;
        _notify();
      }
      final sourceReady = await service.commit(source, imports);
      if (isCancelling || operation != _operation) {
        await service.remove(source.id);
        return;
      }
      credentialMayExist = true;
      await _credentialStore.write(
        key: source.credentialKey,
        username: source.username,
        password: password,
        serverUrl: source.serverUrl,
      );
      if (isCancelling || operation != _operation) {
        await _cleanupTestNonReady(
          service,
          source.id,
          source.credentialKey,
          credentialMayExist,
        );
        return;
      }
      ready = sourceReady;
      persisted = PersistedSource(
        id: source.id,
        name: source.name,
        credentialKey: source.credentialKey,
        counts: sourceReady.counts,
      );
    } on SourceImportFailure catch (error) {
      await _cleanupTestNonReady(
        service,
        source.id,
        source.credentialKey,
        credentialMayExist,
      );
      _markCurrentStageError();
      failure = error.kind;
    } catch (_) {
      await _cleanupTestNonReady(
        service,
        source.id,
        source.credentialKey,
        credentialMayExist,
      );
      _markCurrentStageError();
      failure = SourceImportFailureKind.emptyResponse;
    } finally {
      isImporting = false;
      _notify();
    }
  }

  Future<void> _cleanupTestNonReady(
    SourceSetupPort service,
    String sourceId,
    String credentialKey,
    bool credentialMayExist,
  ) async {
    if (credentialMayExist) {
      try {
        await _credentialStore.delete(credentialKey);
      } catch (_) {}
    }
    try {
      await service.remove(sourceId);
    } catch (_) {}
  }

  /// Cancellation remains busy until worker acknowledgement and cleanup. This
  /// deliberately prevents a second import from racing a forced HttpClient close.
  Future<void> cancel() async {
    if (!isImporting || isCancelling) return;
    ++_operation;
    isCancelling = true;
    _notify();
    final m3uRefresh = _m3uRefresh;
    if (m3uRefresh != null) {
      try {
        await m3uRefresh.cancel();
        await m3uRefresh.completed;
      } catch (_) {}
      _m3uRefresh = null;
    }
    var import = _import;
    if (import == null && _beginning != null) {
      try {
        import = await _beginning;
      } catch (_) {}
    }
    if (import != null) {
      try {
        await import.cancel();
      } catch (_) {}
    }
    isImporting = false;
    isCancelling = false;
    _import = null;
    failure = null;
    ready = null;
    fieldErrors = const {};
    _resetStages();
    _notify();
  }

  Future<void> refreshM3uSource(
    String sourceId, {
    String? replacementLocator,
  }) async {
    if (_service == null || busy) {
      return;
    }
    final record = await _service.sourceOperation(sourceId);
    if (record == null ||
        (record.kind != 'm3u_url' && record.kind != 'm3u_file')) {
      return;
    }
    final locator =
        replacementLocator ??
        (await _credentialStore.read(record.credentialKey))?.serverUrl;
    if (locator == null || locator.isEmpty) {
      failure = SourceImportFailureKind.emptyResponse;
      _notify();
      return;
    }
    isImporting = true;
    failure = null;
    _resetStages();
    _stages[SourceMediaKind.live] = ImportStageStatus.importing;
    _notify();
    try {
      if (replacementLocator != null) {
        await _credentialStore.write(
          key: record.credentialKey,
          username: '',
          password: '',
          serverUrl: locator,
        );
      }
      final refresh = await _service.beginM3uRefresh(
        sourceId: sourceId,
        locator: locator,
        isUrl: record.kind == 'm3u_url',
      );
      _m3uRefresh = refresh;
      final result = await refresh.completed;
      _m3uRefresh = null;
      ready = result;
      _stages[SourceMediaKind.live] = ImportStageStatus.complete;
    } on SourceImportFailure catch (error) {
      failure = error.kind == SourceImportFailureKind.cancelled
          ? null
          : error.kind;
      _markCurrentStageError();
    } finally {
      isImporting = false;
      _notify();
    }
  }

  Future<List<SourceRosterEntry>> loadSourceRoster() async =>
      _service == null ? const [] : _service.loadSourceRoster();

  /// Loads a selected source's secret values only into the in-memory editor.
  /// Nothing from this draft is written until [saveEditor] validates it.
  Future<SourceEditorDraft?> loadEditor(SourceEditorRequest request) async {
    if (_service == null) return null;
    final record = await _service.sourceOperation(request.sourceId);
    if (record == null) return null;
    final credential = await _credentialStore.read(record.credentialKey);
    if (credential == null || credential.serverUrl == null) return null;
    return SourceEditorDraft(
      sourceId: record.id,
      credentialKey: record.credentialKey,
      kind: SourceEditorKindLabels.fromDatabaseKind(record.kind),
      name: request.sourceName,
      endpoint: credential.serverUrl!,
      username: credential.username,
      password: credential.password,
    );
  }

  /// Saves an existing connector and immediately refreshes the DB-owned source.
  /// On refresh failure the supplied values remain both in this caller's fields
  /// and in OS credential storage so Retry repeats the user's replacement.
  Future<bool> saveEditor({
    required SourceEditorDraft draft,
    required String name,
    required String endpoint,
    required String username,
    required String password,
  }) async {
    if (_service == null || busy) return false;
    final errors = _validateEditor(
      kind: draft.kind,
      name: name,
      endpoint: endpoint,
      username: username,
      password: password,
    );
    if (errors.isNotEmpty) {
      fieldErrors = errors;
      failure = null;
      _notify();
      return false;
    }

    final normalizedName = name.trim();
    final normalizedEndpoint = endpoint.trim();
    final normalizedUsername = username.trim();
    fieldErrors = const {};
    failure = null;
    await _service.renameSource(draft.sourceId, normalizedName);
    if (draft.kind == SourceEditorKind.xtream) {
      final normalized = _validate(
        name: normalizedName,
        serverUrl: normalizedEndpoint,
        username: normalizedUsername,
        password: password,
      );
      await _credentialStore.write(
        key: draft.credentialKey,
        username: normalized.username!,
        password: password,
        serverUrl: normalized.serverUrl,
      );
      await refreshManagedSource(draft.sourceId);
    } else {
      await refreshM3uSource(
        draft.sourceId,
        replacementLocator: normalizedEndpoint,
      );
    }
    return failure == null;
  }

  Future<void> renameManagedSource(String sourceId, String name) async {
    if (_service == null || busy) return;
    await _service.renameSource(sourceId, name.trim());
    if (!_disposed) notifyListeners();
  }

  Map<String, String> _validateEditor({
    required SourceEditorKind kind,
    required String name,
    required String endpoint,
    required String username,
    required String password,
  }) {
    if (kind == SourceEditorKind.xtream) {
      return _validate(
        name: name,
        serverUrl: endpoint,
        username: username,
        password: password,
      ).errors;
    }
    final errors = <String, String>{};
    if (name.trim().isEmpty) errors['name'] = 'Enter a source name.';
    if (endpoint.trim().isEmpty) {
      errors['endpoint'] = kind == SourceEditorKind.m3uUrl
          ? 'Enter the M3U URL.'
          : 'Choose an M3U file.';
    } else if (kind == SourceEditorKind.m3uUrl) {
      final parsed = Uri.tryParse(endpoint.trim());
      if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
        errors['endpoint'] = 'Enter a valid M3U URL.';
      }
    }
    return errors;
  }

  Future<void> refreshManagedSource(String sourceId) async {
    if (_service == null || busy) return;
    final record = await _service.sourceOperation(sourceId);
    if (record == null) return;
    if (record.kind == 'm3u_url' || record.kind == 'm3u_file') {
      await refreshM3uSource(sourceId);
      return;
    }
    if (record.kind != 'xtream') return;
    final credential = await _credentialStore.read(record.credentialKey);
    if (credential == null || credential.serverUrl == null) {
      failure = SourceImportFailureKind.emptyResponse;
      _notify();
      return;
    }
    isImporting = true;
    failure = null;
    _resetStages();
    _notify();
    try {
      final refresh = await _service.beginXtreamRefresh(
        sourceId: sourceId,
        credential: credential,
      );
      _m3uRefresh = refresh;
      final result = await refresh.completed;
      ready = result;
      for (final kind in SourceMediaKind.values) {
        _stages[kind] = ImportStageStatus.complete;
      }
    } on SourceImportFailure catch (error) {
      failure = error.kind == SourceImportFailureKind.cancelled
          ? null
          : error.kind;
      _markCurrentStageError();
    } finally {
      _m3uRefresh = null;
      isImporting = false;
      _notify();
    }
  }

  Future<bool> removeManagedSource(String sourceId) async {
    if (_service == null || busy) return false;
    final record = await _service.sourceOperation(sourceId);
    if (record == null) return false;
    final prior = await _credentialStore.read(record.credentialKey);
    if (prior != null) {
      try {
        await _credentialStore.delete(record.credentialKey);
      } catch (_) {
        failure = SourceImportFailureKind.emptyResponse;
        _notify();
        return false;
      }
    }
    try {
      await _service.removeSource(sourceId);
      await _reloadPersistedReady();
      _notify();
      return true;
    } catch (_) {
      if (prior != null) {
        try {
          await _credentialStore.write(
            key: record.credentialKey,
            username: prior.username,
            password: prior.password,
            serverUrl: prior.serverUrl,
          );
        } catch (_) {}
      }
      failure = SourceImportFailureKind.emptyResponse;
      _notify();
      return false;
    }
  }

  Future<void> setManagedSourceEnabled(String sourceId, bool enabled) async {
    if (_service == null) return;
    await _service.setEnabled(sourceId, enabled);
    await _reloadPersistedReady();
    _notify();
  }

  Future<void> _reloadPersistedReady() async {
    final loaded = await _service!.loadReady();
    persisted = loaded;
    ready = loaded?.ready;
  }

  void dismissFailure() {
    failure = null;
    _resetStages();
    _notify();
  }

  void _markCurrentStageError() {
    for (final kind in SourceMediaKind.values) {
      if (_stages[kind] == ImportStageStatus.importing) {
        _stages[kind] = ImportStageStatus.error;
        return;
      }
    }
  }

  void _resetStages() {
    for (final kind in SourceMediaKind.values) {
      _stages[kind] = ImportStageStatus.waiting;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  _ValidatedSource _validate({
    required String name,
    required String serverUrl,
    required String username,
    required String password,
  }) {
    final errors = <String, String>{};
    final trimmedName = name.trim();
    final trimmedUsername = username.trim();
    final parsed = Uri.tryParse(serverUrl.trim());
    if (trimmedName.isEmpty) errors['name'] = 'Enter a source name.';
    if (parsed == null ||
        !parsed.hasScheme ||
        (parsed.scheme != 'http' && parsed.scheme != 'https') ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasQuery ||
        parsed.hasFragment) {
      errors['serverUrl'] = 'Enter the provider server URL only.';
    }
    if (trimmedUsername.isEmpty) {
      errors['username'] = 'Enter the account username.';
    }
    if (password.isEmpty) errors['password'] = 'Enter the account password.';
    return _ValidatedSource(
      errors: errors,
      name: trimmedName,
      serverUrl: parsed
          ?.replace(path: parsed.path.replaceFirst(RegExp(r'/+$'), ''))
          .toString(),
      username: trimmedUsername,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    final import = _import;
    if (import != null) {
      unawaited(import.cancel());
    } else if (_beginning != null) {
      unawaited(_beginning!.then((value) => value.cancel()));
    }
    final m3uRefresh = _m3uRefresh;
    if (m3uRefresh != null) unawaited(m3uRefresh.cancel());
    super.dispose();
  }
}

class _ValidatedSource {
  const _ValidatedSource({
    required this.errors,
    this.name,
    this.serverUrl,
    this.username,
  });
  final Map<String, String> errors;
  final String? name;
  final String? serverUrl;
  final String? username;
}
