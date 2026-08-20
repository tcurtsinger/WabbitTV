import 'source_models.dart';

enum StartupTarget { home, previousScreen, lastChannel }

extension StartupTargetStorage on StartupTarget {
  String get storageValue => switch (this) {
    StartupTarget.home => 'home',
    StartupTarget.previousScreen => 'previous_screen',
    StartupTarget.lastChannel => 'last_channel',
  };

  static StartupTarget? tryDecode(String? value) => switch (value) {
    'home' => StartupTarget.home,
    'previous_screen' => StartupTarget.previousScreen,
    'last_channel' => StartupTarget.lastChannel,
    _ => null,
  };
}

/// Stable top-level destinations only. Playback and management continuations
/// deliberately have no durable slug.
enum StartupDestinationSlug {
  home,
  live,
  movies,
  series,
  search,
  library,
  settings,
  guide,
}

class StartupPreference {
  const StartupPreference({
    required this.target,
    required this.previousDestination,
    required this.lastLiveLibraryItemId,
  });

  const StartupPreference.defaults()
    : target = StartupTarget.home,
      previousDestination = null,
      lastLiveLibraryItemId = null;

  final StartupTarget target;
  final StartupDestinationSlug? previousDestination;
  final String? lastLiveLibraryItemId;

  @override
  String toString() =>
      'StartupPreference(target: ${target.storageValue}, '
      'previousDestination: ${previousDestination?.name}, '
      'hasLastLiveItem: ${lastLiveLibraryItemId != null})';
}

class StartupResolution {
  const StartupResolution({
    required this.destination,
    required this.lastLiveItem,
  });

  const StartupResolution.home()
    : destination = StartupDestinationSlug.home,
      lastLiveItem = null;

  final StartupDestinationSlug destination;
  final LibraryCatalogItem? lastLiveItem;

  bool get opensLastChannel => lastLiveItem != null;
}
