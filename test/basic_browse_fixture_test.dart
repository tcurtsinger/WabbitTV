import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/main.dart';
import 'package:wabbit_tv/src/app_shell.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/home_fixture_mode.dart';
import 'package:wabbit_tv/src/spikes/phase1/basic_browse_fixture.dart';

void main() {
  test('fixture is bounded, categorized, and network-free', () async {
    const data = BasicBrowseFixtureData();
    final categories = await data.browseCategories(
      sourceId: BasicBrowseFixtureData.source.id,
      kind: SourceMediaKind.movies,
    );
    final all = await data.browsePage(
      sourceId: BasicBrowseFixtureData.source.id,
      kind: SourceMediaKind.movies,
      selection: categories.first.selection,
      limit: 100,
    );
    final drama = await data.browsePage(
      sourceId: BasicBrowseFixtureData.source.id,
      kind: SourceMediaKind.movies,
      selection: categories[1].selection,
      limit: 100,
    );

    expect(categories.first.name, 'All Movies');
    expect(all.items, hasLength(36));
    expect(drama.items, isNotEmpty);
    expect(
      all.items.every((item) => item.sourceId == 'basic-browse-fixture'),
      isTrue,
    );
    expect(
      all.items.every((item) => item.artworkLocator!.startsWith('fixture:')),
      isTrue,
    );
  });

  testWidgets('fixture can enter the packaged shell directly', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const WabbitApp(
        fixtureMode: HomeFixtureMode.noPersonalization,
        browseSource: BasicBrowseFixtureData.source,
        browseData: BasicBrowseFixtureData(),
        initialDestination: ShellDestination.live,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('All Live'), findsAtLeastNWidgets(1));
    expect(find.textContaining('Fixture source'), findsOneWidget);
    expect(find.text('City Desk'), findsOneWidget);
  });
}
