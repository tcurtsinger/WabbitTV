import 'dart:async';

import 'package:flutter/foundation.dart';

import 'credential_store.dart';
import 'source_catalog_database.dart';
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
  SourceSetupService({SourceCatalogDatabase? database})
    : _database = database ?? const SourceCatalogDatabase();
  final SourceCatalogDatabase _database;

  Future<InitialSourceImport> begin(SourceDefinition source) =>
      _database.beginInitialImport(source);
  Future<void> recoverPending(CredentialStore credentials) =>
      _database.recoverPending(credentials);
  Future<PersistedSource?> loadReady() => _database.loadReadySource();
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
