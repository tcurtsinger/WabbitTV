import 'dart:async';

import 'package:flutter/foundation.dart';

import '../sources/source_catalog_database.dart';
import '../sources/startup_models.dart';

enum StartupPreferencesState { loading, ready, saving, loadFailed, saveFailed }

/// Narrow app-settings boundary shared by cold-start routing and General
/// Settings. All values are credential-free local identities or stable slugs.
abstract interface class StartupPreferencesPort {
  Future<StartupPreference> loadStartupPreference();
  Future<StartupPreference> saveStartupTarget(StartupTarget target);
  Future<StartupPreference> savePreviousDestination(
    StartupDestinationSlug destination,
  );
  Future<bool> saveLastLiveLibraryItem(String libraryItemId);
  Future<StartupResolution> resolveStartupDestination();
}

class DatabaseStartupPreferencesPort implements StartupPreferencesPort {
  const DatabaseStartupPreferencesPort(this.database);

  final SourceCatalogDatabase database;

  @override
  Future<StartupPreference> loadStartupPreference() =>
      database.loadStartupPreference();

  @override
  Future<StartupResolution> resolveStartupDestination() =>
      database.resolveStartupDestination();

  @override
  Future<bool> saveLastLiveLibraryItem(String libraryItemId) =>
      database.saveLastLiveLibraryItem(libraryItemId);

  @override
  Future<StartupPreference> savePreviousDestination(
    StartupDestinationSlug destination,
  ) => database.savePreviousDestination(destination);

  @override
  Future<StartupPreference> saveStartupTarget(StartupTarget target) =>
      database.saveStartupTarget(target);
}

/// One shell-lifetime owner for startup preference reads and writes.
///
/// SQLite commits each setting atomically, but user actions and destination
/// changes can arrive close together. This controller queues every write so
/// their invocation order is also their durable order.
class StartupPreferencesController extends ChangeNotifier {
  StartupPreferencesController({required this.port});

  final StartupPreferencesPort port;

  StartupPreferencesState state = StartupPreferencesState.loading;
  StartupPreference preference = const StartupPreference.defaults();
  String? recovery;

  StartupTarget? _pendingTarget;
  StartupTarget? _failedTarget;
  Future<void>? _load;
  Future<void> _writeTail = Future<void>.value();
  int _targetGeneration = 0;
  bool _disposed = false;

  StartupTarget get displayedTarget => _pendingTarget ?? preference.target;

  Future<void> initialize() => _load ??= _loadPreference();

  Future<void> retry() {
    if (state == StartupPreferencesState.saveFailed && _failedTarget != null) {
      return setTarget(_failedTarget!);
    }
    _load = null;
    return initialize();
  }

  Future<void> setTarget(StartupTarget target) async {
    if (target == displayedTarget &&
        state != StartupPreferencesState.saveFailed) {
      return;
    }
    final generation = ++_targetGeneration;
    _pendingTarget = target;
    _failedTarget = null;
    state = StartupPreferencesState.saving;
    recovery = null;
    _notify();
    try {
      final saved = await _enqueue(() => port.saveStartupTarget(target));
      if (generation != _targetGeneration) return;
      preference = saved;
      _pendingTarget = null;
      state = StartupPreferencesState.ready;
      recovery = null;
    } catch (_) {
      if (generation != _targetGeneration) return;
      _pendingTarget = null;
      _failedTarget = target;
      state = StartupPreferencesState.saveFailed;
      recovery = 'The startup choice could not be saved. Your previous choice is unchanged.';
    } finally {
      if (generation == _targetGeneration) _notify();
    }
  }

  Future<void> savePreviousDestination(
    StartupDestinationSlug destination,
  ) async {
    final saved = await _enqueue(
      () => port.savePreviousDestination(destination),
    );
    preference = saved;
    _notify();
  }

  Future<bool> saveLastLiveLibraryItem(String libraryItemId) async {
    final saved = await _enqueue(
      () => port.saveLastLiveLibraryItem(libraryItemId),
    );
    if (saved) {
      preference = StartupPreference(
        target: preference.target,
        previousDestination: preference.previousDestination,
        lastLiveLibraryItemId: libraryItemId,
      );
      _notify();
    }
    return saved;
  }

  Future<StartupResolution> resolveStartupDestination() async {
    await _writeTail;
    return port.resolveStartupDestination();
  }

  Future<void> _loadPreference() async {
    state = StartupPreferencesState.loading;
    recovery = null;
    _notify();
    try {
      preference = await port.loadStartupPreference();
      state = StartupPreferencesState.ready;
    } catch (_) {
      preference = const StartupPreference.defaults();
      state = StartupPreferencesState.loadFailed;
      recovery =
          'The startup choice could not be loaded. Wabbit will use Home.';
    } finally {
      _notify();
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final operation = _writeTail.then((_) => action());
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
