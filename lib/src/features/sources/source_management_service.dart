import 'source_management_screen.dart';
import 'source_models.dart';
import 'source_setup_controller.dart';

/// Fixed, credential-free failures used by source-management callers.
enum SourceManagementFailureKind {
  unavailable,
  sourceMissing,
  operationInProgress,
  refreshFailed,
  updateFailed,
  renameFailed,
  removeFailed,
  editUnavailable,
}

class SourceManagementFailure implements Exception {
  const SourceManagementFailure(this.kind);
  final SourceManagementFailureKind kind;
}

/// Production bridge from the shaped source-management surface to the existing
/// source setup lifecycle. It intentionally adds no connector or database
/// abstraction: SourceSetupController remains the single owner of refresh,
/// credential deletion/rollback, and connector dispatch.
class SourceManagementService
    implements SourceManagementPort, SourceConnectionAllowancePort {
  SourceManagementService({
    required this.sourceController,
    this.onEditAndRefresh,
  });

  final SourceSetupController sourceController;

  /// Shell/editor integration point. Completion means the editor closed;
  /// saved changes refresh immediately, while Cancel changes nothing.
  final Future<void> Function(String sourceId)? onEditAndRefresh;
  bool _operationActive = false;

  @override
  Future<List<SourceRosterEntry>> loadRoster() =>
      sourceController.loadSourceRoster();

  @override
  Future<SourceConnectionAllowance> loadSourceConnectionAllowance(
    String sourceId,
  ) async {
    try {
      final allowance = await sourceController.loadSourceConnectionAllowance(
        sourceId,
      );
      if (allowance == null) {
        throw const SourceManagementFailure(
          SourceManagementFailureKind.sourceMissing,
        );
      }
      return allowance;
    } on SourceManagementFailure {
      rethrow;
    } catch (_) {
      throw const SourceManagementFailure(
        SourceManagementFailureKind.unavailable,
      );
    }
  }

  @override
  Future<SourceConnectionAllowance> setSourceConnectionLimitOverride({
    required String sourceId,
    required int? overrideLimit,
  }) => _run(() async {
    final allowance = await sourceController.setSourceConnectionLimitOverride(
      sourceId: sourceId,
      overrideLimit: overrideLimit,
    );
    if (allowance == null) {
      throw const SourceManagementFailure(
        SourceManagementFailureKind.updateFailed,
      );
    }
    return allowance;
  });

  @override
  Future<void> refresh(String sourceId) => _run(() async {
    await _requireSource(sourceId);
    if (sourceController.busy) {
      throw const SourceManagementFailure(
        SourceManagementFailureKind.operationInProgress,
      );
    }
    await sourceController.refreshManagedSource(sourceId);
    if (sourceController.failure != null) {
      throw const SourceManagementFailure(
        SourceManagementFailureKind.refreshFailed,
      );
    }
  });

  @override
  Future<void> setEnabled(String sourceId, bool enabled) => _run(() async {
    await _requireSource(sourceId);
    if (sourceController.busy) {
      throw const SourceManagementFailure(
        SourceManagementFailureKind.operationInProgress,
      );
    }
    await sourceController.setManagedSourceEnabled(sourceId, enabled);
    final updated = await _requireSource(sourceId);
    if (updated.enabled != enabled) {
      throw const SourceManagementFailure(
        SourceManagementFailureKind.updateFailed,
      );
    }
  });

  @override
  Future<void> rename(String sourceId, String name) => _run(() async {
    final normalized = name.trim();
    await _requireSource(sourceId);
    if (normalized.isEmpty || sourceController.busy) {
      throw const SourceManagementFailure(
        SourceManagementFailureKind.renameFailed,
      );
    }
    await sourceController.renameManagedSource(sourceId, normalized);
    final updated = await _requireSource(sourceId);
    if (updated.name != normalized) {
      throw const SourceManagementFailure(
        SourceManagementFailureKind.renameFailed,
      );
    }
  });

  @override
  Future<void> editAndRefresh(String sourceId) => _run(() async {
    await _requireSource(sourceId);
    final edit = onEditAndRefresh;
    if (edit == null) {
      throw const SourceManagementFailure(
        SourceManagementFailureKind.editUnavailable,
      );
    }
    await edit(sourceId);
  });

  @override
  Future<void> remove(String sourceId) => _run(() async {
    await _requireSource(sourceId);
    if (sourceController.busy) {
      throw const SourceManagementFailure(
        SourceManagementFailureKind.operationInProgress,
      );
    }
    final removed = await sourceController.removeManagedSource(sourceId);
    if (!removed || (await _findSource(sourceId)) != null) {
      throw const SourceManagementFailure(
        SourceManagementFailureKind.removeFailed,
      );
    }
  });

  Future<T> _run<T>(Future<T> Function() action) async {
    if (_operationActive) {
      throw const SourceManagementFailure(
        SourceManagementFailureKind.operationInProgress,
      );
    }
    _operationActive = true;
    try {
      return await action();
    } on SourceManagementFailure {
      rethrow;
    } catch (_) {
      throw const SourceManagementFailure(
        SourceManagementFailureKind.unavailable,
      );
    } finally {
      _operationActive = false;
    }
  }

  Future<SourceRosterEntry> _requireSource(String sourceId) async {
    final source = await _findSource(sourceId);
    if (source == null) {
      throw const SourceManagementFailure(
        SourceManagementFailureKind.sourceMissing,
      );
    }
    return source;
  }

  Future<SourceRosterEntry?> _findSource(String sourceId) async {
    final roster = await loadRoster();
    for (final source in roster) {
      if (source.id == sourceId) return source;
    }
    return null;
  }
}
