import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:wabbit_tv/src/features/settings/startup_preferences_controller.dart';
import 'package:wabbit_tv/src/features/sources/startup_models.dart';

void main() {
  test('missing preference read stays truthful and defaults to Home', () async {
    final port = _StartupPort()..failLoad = true;
    final controller = StartupPreferencesController(port: port);
    addTearDown(controller.dispose);

    await controller.initialize();

    expect(controller.state, StartupPreferencesState.loadFailed);
    expect(controller.displayedTarget, StartupTarget.home);
    expect(controller.recovery, contains('will use Home'));

    port.failLoad = false;
    await controller.retry();
    expect(controller.state, StartupPreferencesState.ready);
    expect(controller.displayedTarget, StartupTarget.home);
  });

  test('rapid startup choices serialize and the final action wins', () async {
    final firstSave = Completer<void>();
    final port = _StartupPort()..firstTargetSave = firstSave.future;
    final controller = StartupPreferencesController(port: port);
    addTearDown(controller.dispose);
    await controller.initialize();

    final first = controller.setTarget(StartupTarget.previousScreen);
    await Future<void>.delayed(Duration.zero);
    final second = controller.setTarget(StartupTarget.lastChannel);
    await Future<void>.delayed(Duration.zero);

    expect(port.savedTargets, [StartupTarget.previousScreen]);
    expect(controller.displayedTarget, StartupTarget.lastChannel);

    firstSave.complete();
    await Future.wait([first, second]);

    expect(port.savedTargets, [
      StartupTarget.previousScreen,
      StartupTarget.lastChannel,
    ]);
    expect(controller.state, StartupPreferencesState.ready);
    expect(controller.preference.target, StartupTarget.lastChannel);
  });

  test(
    'failed target save restores prior choice and retries exact intent',
    () async {
      final port = _StartupPort()..failTargetSave = true;
      final controller = StartupPreferencesController(port: port);
      addTearDown(controller.dispose);
      await controller.initialize();

      await controller.setTarget(StartupTarget.lastChannel);

      expect(controller.state, StartupPreferencesState.saveFailed);
      expect(controller.displayedTarget, StartupTarget.home);
      expect(controller.recovery, contains('previous choice is unchanged'));

      port.failTargetSave = false;
      await controller.retry();
      expect(controller.state, StartupPreferencesState.ready);
      expect(controller.displayedTarget, StartupTarget.lastChannel);
    },
  );

  test('destination and last-channel writes share one ordered queue', () async {
    final destinationSave = Completer<void>();
    final port = _StartupPort()..destinationSave = destinationSave.future;
    final controller = StartupPreferencesController(port: port);
    addTearDown(controller.dispose);
    await controller.initialize();

    final destination = controller.savePreviousDestination(
      StartupDestinationSlug.movies,
    );
    await Future<void>.delayed(Duration.zero);
    final last = controller.saveLastLiveLibraryItem('library-live');
    await Future<void>.delayed(Duration.zero);

    expect(port.operations, ['destination:movies']);
    destinationSave.complete();
    await destination;
    expect(await last, isTrue);
    expect(port.operations, ['destination:movies', 'last:library-live']);
  });
}

class _StartupPort implements StartupPreferencesPort {
  StartupPreference value = const StartupPreference.defaults();
  bool failLoad = false;
  bool failTargetSave = false;
  Future<void>? firstTargetSave;
  Future<void>? destinationSave;
  final savedTargets = <StartupTarget>[];
  final operations = <String>[];

  @override
  Future<StartupPreference> loadStartupPreference() async {
    if (failLoad) throw StateError('private load failure');
    return value;
  }

  @override
  Future<StartupResolution> resolveStartupDestination() async =>
      const StartupResolution.home();

  @override
  Future<bool> saveLastLiveLibraryItem(String libraryItemId) async {
    operations.add('last:$libraryItemId');
    value = StartupPreference(
      target: value.target,
      previousDestination: value.previousDestination,
      lastLiveLibraryItemId: libraryItemId,
    );
    return true;
  }

  @override
  Future<StartupPreference> savePreviousDestination(
    StartupDestinationSlug destination,
  ) async {
    operations.add('destination:${destination.name}');
    final pending = destinationSave;
    if (pending != null) await pending;
    value = StartupPreference(
      target: value.target,
      previousDestination: destination,
      lastLiveLibraryItemId: value.lastLiveLibraryItemId,
    );
    return value;
  }

  @override
  Future<StartupPreference> saveStartupTarget(StartupTarget target) async {
    savedTargets.add(target);
    final pending = firstTargetSave;
    if (savedTargets.length == 1 && pending != null) await pending;
    if (failTargetSave) throw StateError('private save failure');
    value = StartupPreference(
      target: target,
      previousDestination: value.previousDestination,
      lastLiveLibraryItemId: value.lastLiveLibraryItemId,
    );
    return value;
  }
}
