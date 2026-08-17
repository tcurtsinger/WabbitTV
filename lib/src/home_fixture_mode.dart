enum HomeFixtureMode {
  /// Normal application runtime. Shell resolves persisted catalog state.
  runtime,
  populated,
  noSources,
  noPersonalization;

  static HomeFixtureMode fromEnvironment() {
    return switch (const String.fromEnvironment(
      'WABBIT_HOME_FIXTURE',
      defaultValue: 'runtime',
    )) {
      'populated' => HomeFixtureMode.populated,
      'no-sources' => HomeFixtureMode.noSources,
      'no-personalization' => HomeFixtureMode.noPersonalization,
      _ => HomeFixtureMode.runtime,
    };
  }
}
