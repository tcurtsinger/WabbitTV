import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/sources/library_visibility_screen.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  Widget app(
    _Port port, {
    VoidCallback? onBack,
    FocusNode? initialFocus,
    ValueChanged<FocusNode>? onContentFocus,
    ValueChanged<bool>? onBusyChanged,
  }) => MaterialApp(
    home: Scaffold(
      body: LibraryVisibilityScreen(
        sourceId: 'strong',
        sourceName: 'Strong',
        port: port,
        initialFocus: initialFocus ?? FocusNode(debugLabel: 'visibility entry'),
        onContentFocus: onContentFocus ?? (_) {},
        onBack: onBack ?? () {},
        onBusyChanged: onBusyChanged,
      ),
    ),
  );

  testWidgets('directory and ledger show the confirmed first viewport', (
    tester,
  ) async {
    final port = _Port();
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    expect(find.text('Manage visibility'), findsOneWidget);
    expect(find.textContaining('Local visibility only'), findsOneWidget);
    expect(find.text('Provider categories'), findsOneWidget);
    expect(find.text('Hide category'), findsOneWidget);
    expect(find.text('Film Select'), findsOneWidget);
    expect(find.text('56,712'), findsWidgets);
    expect(find.text('Included'), findsWidgets);
  });

  testWidgets('entry and owned action focus are reported to the shell', (
    tester,
  ) async {
    final initialFocus = FocusNode(debugLabel: 'visibility supplied entry');
    addTearDown(initialFocus.dispose);
    final reported = <String?>[];
    await tester.pumpWidget(
      app(
        _Port(),
        initialFocus: initialFocus,
        onContentFocus: (node) => reported.add(node.debugLabel),
      ),
    );
    await tester.pumpAndSettle();
    initialFocus.requestFocus();
    await tester.pump();
    _focusNode(tester, 'library visibility movies').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide category'));
    await tester.pumpAndSettle();
    expect(
      reported,
      containsAll([
        'visibility supplied entry',
        'library visibility movies',
        'library visibility category action',
      ]),
    );
    await tester.pumpWidget(const SizedBox());
    expect(() => initialFocus.requestFocus(), returnsNormally);
  });

  testWidgets('D-pad graph connects header, category action, and item pane', (
    tester,
  ) async {
    final back = FocusNode(debugLabel: 'visibility back graph');
    addTearDown(back.dispose);
    await tester.pumpWidget(app(_Port(), initialFocus: back));
    await tester.pumpAndSettle();
    back.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility hidden only',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility live',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility hide all',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility category news',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility category action',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility category news',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility item live-1',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility category news',
    );
  });

  testWidgets('buttons reserve fixed two-pixel amber focus edges', (
    tester,
  ) async {
    final back = FocusNode(debugLabel: 'visibility border back');
    addTearDown(back.dispose);
    await tester.pumpWidget(app(_Port(), initialFocus: back));
    await tester.pumpAndSettle();
    final button = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('visibility-action-Back')),
    );
    expect(button.style?.side?.resolve({})?.width, 2);
    expect(
      button.style?.side?.resolve({WidgetState.focused})?.color,
      const Color(0xFFFFB347),
    );
    expect(button.style?.side?.resolve({WidgetState.focused})?.width, 2);
    final selectedKind = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('visibility-kind-live')),
    );
    expect(selectedKind.style?.side?.resolve({})?.width, 2);
    expect(
      selectedKind.style?.side?.resolve({})?.color,
      const Color(0xFFFFB347),
    );
    expect(
      selectedKind.style?.side?.resolve({WidgetState.focused})?.color,
      const Color(0xFFF4F0E7),
    );
    final primary = tester.widget<FilledButton>(
      find.byKey(const ValueKey('visibility-action-Hide category')),
    );
    expect(primary.style?.side?.resolve({})?.width, 2);
    expect(primary.style?.side?.resolve({WidgetState.focused})?.width, 2);
    expect(
      primary.style?.side?.resolve({WidgetState.focused})?.color,
      isNot(primary.style?.side?.resolve({})?.color),
    );
  });

  testWidgets(
    'selecting a category is separate from its explicit visibility action',
    (tester) async {
      final port = _Port();
      await tester.pumpWidget(app(port));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('visibility-category-sports')),
      );
      await tester.pumpAndSettle();
      expect(port.categoryChanges, isEmpty);
      expect(find.text('Sports'), findsWidgets);
      await tester.tap(find.text('Hide category'));
      await tester.pumpAndSettle();
      expect(port.categoryChanges, [(SourceMediaKind.live, 'sports', true)]);
      expect(find.text('Restore category'), findsOneWidget);
    },
  );

  testWidgets(
    'item toggle is local, accessible, and does not change category preference',
    (tester) async {
      final port = _Port();
      await tester.pumpWidget(app(port));
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('visibility-item-live-1'));
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(port.itemChanges, [('live-1', true)]);
      expect(port.categoryChanges, isEmpty);
      expect(find.text('Hidden'), findsWidgets);
    },
  );

  testWidgets('Hidden only is a recovery view with its direct return action', (
    tester,
  ) async {
    final port = _Port();
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('visibility-item-live-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hidden only'));
    await tester.pumpAndSettle();
    expect(find.text('Hidden only: on'), findsOneWidget);
    expect(find.text('News One'), findsOneWidget);
    expect(find.text('Sports'), findsNothing);
    await tester.tap(find.text('Hidden only: on'));
    await tester.pumpAndSettle();
    expect(find.text('Film Select'), findsOneWidget);
  });

  testWidgets('restoring a hidden item removes it from the filtered ledger', (
    tester,
  ) async {
    final port = _Port();
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('visibility-item-live-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hidden only'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('visibility-item-live-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('visibility-item-live-1')), findsNothing);
    expect(port.itemChanges, [('live-1', true), ('live-1', false)]);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      isNot('library visibility item live-1'),
    );
  });

  testWidgets(
    'restoring a category removes it from Hidden only when no items remain hidden',
    (tester) async {
      final port = _Port();
      await tester.pumpWidget(app(port));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('visibility-category-sports')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide category'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hidden only'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('visibility-category-sports')),
        findsOneWidget,
      );
      await tester.tap(find.text('Restore category'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('visibility-category-sports')),
        findsNothing,
      );
      expect(port.categoryChanges, [
        (SourceMediaKind.live, 'sports', true),
        (SourceMediaKind.live, 'sports', false),
      ]);
    },
  );

  testWidgets(
    'restoring a category retains individually hidden items and action focus',
    (tester) async {
      final port = _Port();
      await tester.pumpWidget(app(port));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('visibility-category-film')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide category'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hidden only'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore category'));
      await tester.pumpAndSettle();
      expect(find.text('Hidden Film'), findsOneWidget);
      expect(find.text('Hide category'), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'library visibility category action',
      );
    },
  );

  testWidgets('Uncategorized never exposes a category visibility action', (
    tester,
  ) async {
    final port = _Port();
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    final uncategorized = find.byKey(
      const ValueKey('visibility-category-uncategorized'),
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(uncategorized);
    await tester.pumpAndSettle();
    expect(find.text('Uncategorized'), findsWidgets);
    expect(find.text('Hide category'), findsNothing);
    expect(find.text('Restore category'), findsNothing);
    expect(
      find.byKey(const ValueKey('visibility-item-loose-1')),
      findsOneWidget,
    );
  });

  testWidgets(
    'bulk toolbar distinguishes all-included, mixed, and all-hidden',
    (tester) async {
      final port = _Port();
      await tester.pumpWidget(app(port));
      await tester.pumpAndSettle();
      expect(find.text('All 3 categories included'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.descendant(
                of: find.byKey(const ValueKey('visibility-bulk-restore')),
                matching: find.byType(OutlinedButton),
              ),
            )
            .onPressed,
        isNull,
      );
      final restoreSemantics = tester.widget<Semantics>(
        find
            .descendant(
              of: find.byKey(const ValueKey('visibility-bulk-restore')),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(restoreSemantics.properties.enabled, isFalse);
      expect(
        restoreSemantics.properties.hint,
        'All provider categories are already included.',
      );
      port.categoriesHidden['sports'] = true;
      await tester.tap(find.text('Hidden only'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hidden only: on'));
      await tester.pumpAndSettle();
      expect(find.text('2 included · 1 hidden'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.descendant(
                of: find.byKey(const ValueKey('visibility-bulk-hide')),
                matching: find.byType(OutlinedButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.descendant(
                of: find.byKey(const ValueKey('visibility-bulk-restore')),
                matching: find.byType(OutlinedButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('direct category restore updates the bulk toolbar summary', (
    tester,
  ) async {
    final port = _Port()
      ..categoriesHidden.addAll({'news': true, 'sports': true, 'film': true});
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    expect(find.text('All 3 categories hidden'), findsOneWidget);
    await tester.tap(find.text('Restore category'));
    await tester.pumpAndSettle();
    expect(find.text('1 included · 2 hidden'), findsOneWidget);
    expect(port.categoryChanges, [(SourceMediaKind.live, 'news', false)]);
  });

  testWidgets('stale category completion cannot alter a newer kind view', (
    tester,
  ) async {
    final port = _CategoryGatePort();
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide category'));
    await tester.pump();
    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();
    port.pending.complete();
    await tester.pumpAndSettle();

    final movies = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('visibility-kind-movies')),
    );
    expect(movies.style?.backgroundColor?.resolve({}), const Color(0xFFFFB347));
    expect(find.text('All 3 categories included'), findsOneWidget);
    expect(find.text('Restore category'), findsNothing);
    expect(port.categoryChanges, [(SourceMediaKind.live, 'news', true)]);
  });

  testWidgets(
    'Hide all confirms, preserves item preferences, and recovers focus',
    (tester) async {
      final port = _Port();
      await tester.pumpWidget(app(port));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('visibility-bulk-hide')));
      await tester.pump();
      expect(
        find.text(
          'Hide all 3 Live categories from Strong? Individual item choices stay unchanged.',
        ),
        findsOneWidget,
      );
      final confirmation = tester.widget<Semantics>(
        find.byKey(const ValueKey('visibility-bulk-confirmation-message')),
      );
      expect(confirmation.properties.liveRegion, isTrue);
      expect(
        confirmation.properties.label,
        'Hide all 3 Live categories from Strong? Individual item choices stay unchanged.',
      );
      final cancelSemantics = tester.widget<Semantics>(
        find
            .descendant(
              of: find.byKey(const ValueKey('visibility-bulk-cancel')),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(
        cancelSemantics.properties.hint,
        'Cancel hiding all 3 Live categories from Strong. Individual item choices stay unchanged.',
      );
      final confirmSemantics = tester.widget<Semantics>(
        find
            .descendant(
              of: find.byKey(const ValueKey('visibility-bulk-confirm-hide')),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(
        confirmSemantics.properties.hint,
        'Hide all 3 Live categories from Strong. Individual item choices stay unchanged.',
      );
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'library visibility bulk cancel',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'library visibility hide all',
      );
      await tester.tap(find.byKey(const ValueKey('visibility-bulk-hide')));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('visibility-bulk-confirm-hide')),
      );
      await tester.pumpAndSettle();
      expect(port.bulkChanges, [(SourceMediaKind.live, true)]);
      expect(port.itemsHidden['movie-2'], isTrue);
      expect(find.text('All 3 categories hidden'), findsOneWidget);
      final hideSemantics = tester.widget<Semantics>(
        find
            .descendant(
              of: find.byKey(const ValueKey('visibility-bulk-hide')),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(hideSemantics.properties.enabled, isFalse);
      expect(
        hideSemantics.properties.hint,
        'All provider categories are already hidden.',
      );
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'library visibility restore all',
      );
    },
  );

  testWidgets(
    'Restore all is immediate and bulk failure offers retry and cancel',
    (tester) async {
      final port = _Port()..categoriesHidden['sports'] = true;
      await tester.pumpWidget(app(port));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('visibility-bulk-restore')));
      await tester.pumpAndSettle();
      expect(port.bulkChanges, [(SourceMediaKind.live, false)]);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'library visibility hide all',
      );
      port.failBulk = true;
      await tester.tap(find.byKey(const ValueKey('visibility-bulk-hide')));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('visibility-bulk-confirm-hide')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Category visibility was not changed'), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'library visibility bulk retry',
      );
      port.failBulk = false;
      await tester.tap(find.byKey(const ValueKey('visibility-bulk-retry')));
      await tester.pumpAndSettle();
      expect(port.bulkChanges, [
        (SourceMediaKind.live, false),
        (SourceMediaKind.live, true),
      ]);
      expect(port.bulkWriteCalls, 3);
    },
  );

  testWidgets('busy bulk write blocks kind and Hidden only changes', (
    tester,
  ) async {
    final port = _BulkGatePort();
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('visibility-bulk-hide')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('visibility-bulk-confirm-hide')),
    );
    await tester.pump();
    expect(find.text('Updating categories…'), findsOneWidget);
    await tester.tap(find.text('Movies'));
    await tester.tap(find.text('Hidden only'));
    await tester.pump();
    final live = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('visibility-kind-live')),
    );
    expect(live.style?.backgroundColor?.resolve({}), const Color(0xFFFFB347));
    expect(find.text('Hidden only: on'), findsNothing);
    port.pending.complete(3);
    await tester.pumpAndSettle();
    expect(find.text('Updating categories…'), findsNothing);
  });

  testWidgets('pending Hidden-only bulk blocks category and item activation', (
    tester,
  ) async {
    final port = _CommittingBulkGatePort()..categoriesHidden['film'] = true;
    final busyChanges = <bool>[];
    await tester.pumpWidget(app(port, onBusyChanged: busyChanges.add));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hidden only'));
    await tester.pumpAndSettle();
    final categoryLoads = port.categoryLoadCalls;
    final itemLoads = port.itemLoadCalls;

    await tester.tap(find.byKey(const ValueKey('visibility-bulk-restore')));
    await tester.pump();
    await tester.tap(find.text('Restore category'));
    await tester.tap(find.byKey(const ValueKey('visibility-item-movie-2')));
    await tester.pump();

    expect(port.categoryChanges, isEmpty);
    expect(port.itemChanges, isEmpty);
    expect(port.categoryLoadCalls, categoryLoads);
    expect(port.itemLoadCalls, itemLoads);
    expect(busyChanges, [true]);
    expect(find.text('Updating categories…'), findsOneWidget);

    port.pending.complete();
    await tester.pumpAndSettle();
    expect(busyChanges, [true, false]);
    expect(find.text('Updating categories…'), findsNothing);
  });

  testWidgets(
    'post-commit read failure retries only the filtered directory reload',
    (tester) async {
      final port = _Port()..categoriesHidden['sports'] = true;
      final busyChanges = <bool>[];
      await tester.pumpWidget(app(port, onBusyChanged: busyChanges.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hidden only'));
      await tester.pumpAndSettle();
      port.failFilteredAfterBulk = true;
      await tester.tap(find.byKey(const ValueKey('visibility-bulk-restore')));
      await tester.pumpAndSettle();
      expect(port.bulkChanges, [(SourceMediaKind.live, false)]);
      expect(busyChanges, [true, false]);
      expect(
        find.text(
          'Category visibility was saved locally; this view could not refresh',
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('visibility-bulk-retry')));
      await tester.pumpAndSettle();
      expect(port.bulkChanges, [(SourceMediaKind.live, false)]);
      expect(port.bulkWriteCalls, 1);
      expect(busyChanges, [true, false, true, false]);

      port.failFilteredAfterBulk = false;
      await tester.tap(find.byKey(const ValueKey('visibility-bulk-retry')));
      await tester.pumpAndSettle();
      expect(port.bulkChanges, [(SourceMediaKind.live, false)]);
      expect(port.bulkWriteCalls, 1);
      expect(busyChanges, [true, false, true, false, true, false]);
      expect(find.text('All 3 categories included'), findsOneWidget);
    },
  );

  testWidgets(
    'Cancel after a committed refresh failure returns to the full view',
    (tester) async {
      final port = _Port()..categoriesHidden['sports'] = true;
      await tester.pumpWidget(app(port));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hidden only'));
      await tester.pumpAndSettle();
      port.failFilteredAfterBulk = true;
      await tester.tap(find.byKey(const ValueKey('visibility-bulk-restore')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Category visibility was saved locally; this view could not refresh',
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('visibility-bulk-cancel')));
      await tester.pumpAndSettle();
      expect(find.text('Hidden only: on'), findsNothing);
      expect(find.text('All 3 categories included'), findsOneWidget);
      expect(find.text('News'), findsWidgets);
      expect(find.text('Sports'), findsWidgets);
      expect(find.text('Film Select'), findsOneWidget);
      expect(
        find.text(
          'Category visibility was saved locally; this view could not refresh',
        ),
        findsNothing,
      );
    },
  );

  testWidgets('empty Hidden-only restore uses owned recovery focus', (
    tester,
  ) async {
    final port = _Port()
      ..categoriesHidden.addAll({'news': true, 'sports': true, 'film': true})
      ..itemsHidden['movie-2'] = false;
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hidden only'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('visibility-bulk-restore')));
    await tester.pumpAndSettle();

    expect(find.text('Nothing is hidden'), findsOneWidget);
    expect(find.text('Hidden only: on'), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility empty recovery',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Nothing is hidden'), findsNothing);
    expect(find.text('Hidden only: on'), findsNothing);
    expect(find.text('All 3 categories included'), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility hidden only',
    );
  });

  testWidgets('bulk success preserves loaded pages and deep item position', (
    tester,
  ) async {
    final port = _Port(extraNewsItemCount: 8, pageChunkSize: 2);
    await tester.binding.setSurfaceSize(const Size(900, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    _focusNode(tester, 'library visibility item live-2').requestFocus();
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility item news-extra-5',
    );
    final itemList = tester.widgetList<ListView>(find.byType(ListView)).last;
    final itemOffset = itemList.controller!.offset;
    final itemLoadCalls = port.itemLoadCalls;

    await tester.tap(find.byKey(const ValueKey('visibility-bulk-hide')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('visibility-bulk-confirm-hide')),
    );
    await tester.pumpAndSettle();

    expect(port.itemLoadCalls, itemLoadCalls);
    expect(
      tester
          .widgetList<ListView>(find.byType(ListView))
          .last
          .controller!
          .offset,
      itemOffset,
    );
    expect(
      find.byKey(const ValueKey('visibility-item-news-extra-5')),
      findsOneWidget,
    );
  });

  testWidgets('Saving keeps the normal bulk action-row geometry', (
    tester,
  ) async {
    final port = _BulkGatePort();
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    final actionSlot = find.byKey(
      const ValueKey('visibility-bulk-action-slot'),
    );
    final normalSize = tester.getSize(actionSlot);
    final normalDirectoryTop = tester
        .getTopLeft(find.byKey(const ValueKey('visibility-category-news')))
        .dy;
    await tester.tap(find.byKey(const ValueKey('visibility-bulk-hide')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('visibility-bulk-confirm-hide')),
    );
    await tester.pump();
    expect(tester.getSize(actionSlot), normalSize);
    expect(normalSize.height, 40);
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('visibility-category-news')))
          .dy,
      normalDirectoryTop,
    );
    port.pending.complete(3);
    await tester.pumpAndSettle();
  });

  testWidgets(
    'remote Select toggles an item and Escape returns through panes',
    (tester) async {
      var backs = 0;
      final port = _Port();
      await tester.pumpWidget(app(port, onBack: () => backs++));
      await tester.pumpAndSettle();
      final itemFocus = tester
          .widgetList<Focus>(find.byType(Focus))
          .firstWhere(
            (focus) =>
                focus.focusNode?.debugLabel == 'library visibility item live-1',
          )
          .focusNode!;
      itemFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(port.itemChanges, [('live-1', true)]);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'library visibility category news',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(backs, 1);
    },
  );

  testWidgets(
    'loading retains geometry and failure keeps the last local view',
    (tester) async {
      final gate = Completer<List<LibraryVisibilityCategory>>();
      final port = _Port(categoryGate: gate);
      await tester.pumpWidget(app(port));
      expect(find.byKey(const ValueKey('visibility-skeleton')), findsWidgets);
      gate.complete(port.allCategories);
      await tester.pumpAndSettle();
      expect(find.text('News'), findsWidgets);
      port.failCategories = true;
      await tester.tap(find.text('Hidden only'));
      await tester.pumpAndSettle();
      expect(find.text('News'), findsWidgets);
      expect(
        find.text(
          'Visibility could not be updated. Showing your last local view.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('initial load failure has a working Retry action', (
    tester,
  ) async {
    final port = _Port()..failCategories = true;
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    expect(find.text('Visibility could not be loaded'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('No provider categories'), findsNothing);
    port.failCategories = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('News'), findsWidgets);
  });

  testWidgets('initial item failure has an inline Retry action', (
    tester,
  ) async {
    final port = _Port(failItems: true);
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    expect(find.text('Items could not be loaded'), findsOneWidget);
    expect(find.text('Retry items'), findsOneWidget);
    expect(find.text('No available items in this category.'), findsNothing);
    port.failItems = false;
    await tester.tap(find.text('Retry items'));
    await tester.pumpAndSettle();
    expect(find.text('News One'), findsOneWidget);
  });

  testWidgets('directory failure routes keyboard focus to Retry and back', (
    tester,
  ) async {
    final port = _Port()..failCategories = true;
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    _focusNode(tester, 'library visibility live').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility retry',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility live',
    );
  });

  testWidgets('item failure routes keyboard focus to Retry and category', (
    tester,
  ) async {
    await tester.pumpWidget(app(_Port(failItems: true)));
    await tester.pumpAndSettle();
    _focusNode(tester, 'library visibility live').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility retry',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility category news',
    );
  });

  testWidgets('failed Hidden only reload restores the exact usable view', (
    tester,
  ) async {
    final port = _Port();
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    expect(find.text('News One'), findsOneWidget);
    expect(find.text('News Two'), findsOneWidget);
    port.failCategories = true;
    await tester.tap(find.text('Hidden only'));
    await tester.pumpAndSettle();
    expect(find.text('Hidden only'), findsOneWidget);
    expect(find.text('Hidden only: on'), findsNothing);
    expect(find.text('News One'), findsOneWidget);
    expect(find.text('News Two'), findsOneWidget);
    expect(
      find.text(
        'Visibility could not be updated. Showing your last local view.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('failed kind item reload restores kind, selection, and items', (
    tester,
  ) async {
    final port = _Port();
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    port.failItems = true;
    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();
    expect(find.text('News One'), findsOneWidget);
    expect(find.text('News'), findsWidgets);
    final live = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('visibility-kind-live')),
    );
    expect(live.style?.backgroundColor?.resolve({}), const Color(0xFFFFB347));
  });

  testWidgets('superseded directory failure cannot roll back a newer kind', (
    tester,
  ) async {
    final port = _InterleavingDirectoryPort();
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movies'));
    await tester.pump();
    await tester.tap(find.text('Series'));
    await tester.pump();
    port.series.complete(port.allCategories);
    await tester.pumpAndSettle();
    port.movies.completeError(StateError('superseded movie load'));
    await tester.pumpAndSettle();
    final series = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('visibility-kind-series')),
    );
    expect(series.style?.backgroundColor?.resolve({}), const Color(0xFFFFB347));
    expect(find.text('News One'), findsOneWidget);
    expect(find.byKey(const ValueKey('visibility-recovery')), findsNothing);
  });

  testWidgets('narrow layout opens the in-shell category directory overlay', (
    tester,
  ) async {
    final port = _Port();
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('visibility-category-news')),
      findsNothing,
    );
    await tester.tap(find.text('Provider categories'));
    await tester.pump();
    expect(find.text('Close categories'), findsOneWidget);
    expect(find.text('News'), findsWidgets);
    _focusNode(tester, 'library visibility category news').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Provider categories'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('visibility-category-news')),
      findsNothing,
    );
  });

  testWidgets('narrow category selection closes the directory overlay', (
    tester,
  ) async {
    final port = _Port();
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Provider categories'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('visibility-category-sports')));
    await tester.pumpAndSettle();
    expect(find.text('Provider categories'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('visibility-category-sports')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('visibility-item-sport-1')),
      findsOneWidget,
    );
  });

  testWidgets('Back cannot exit a narrow directory during a bulk write', (
    tester,
  ) async {
    var backs = 0;
    final port = _BulkGatePort();
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(port, onBack: () => backs++));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Provider categories'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('visibility-bulk-hide')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('visibility-bulk-confirm-hide')),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.tap(find.text('Movies'));
    await tester.tap(find.text('Hidden only'));
    await tester.pump();
    expect(backs, 0);
    expect(find.text('Close categories'), findsOneWidget);
    expect(find.text('Hidden only: on'), findsNothing);
    final live = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('visibility-kind-live')),
    );
    expect(live.style?.backgroundColor?.resolve({}), const Color(0xFFFFB347));

    port.pending.complete(3);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Provider categories'), findsOneWidget);
    expect(backs, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(backs, 1);
  });

  testWidgets('narrow launcher and Right transfer focus into visible content', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(_Port()));
    await tester.pumpAndSettle();
    final launcher = _focusNode(
      tester,
      'library visibility directory launcher',
    );
    launcher.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility hide all',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('visibility-category-news')),
      findsNothing,
    );
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility category action',
    );
  });

  testWidgets('narrow kind and launcher graph enters the category directory', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(_Port()));
    await tester.pumpAndSettle();
    final series = _focusNode(tester, 'library visibility series');
    series.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility directory launcher',
    );
    series.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility directory launcher',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility hide all',
    );
  });

  testWidgets('keyboard category traversal reveals virtual rows before focus', (
    tester,
  ) async {
    final port = _Port(extraCategoryCount: 24);
    await tester.binding.setSurfaceSize(const Size(900, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    final first = _focusNode(tester, 'library visibility category news');
    first.requestFocus();
    await tester.pump();
    for (var i = 0; i < 16; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility category extra-12',
    );
    expect(
      find.byKey(const ValueKey('visibility-category-extra-12')),
      findsOneWidget,
    );
  });

  testWidgets('keyboard item traversal reveals virtual rows before focus', (
    tester,
  ) async {
    final port = _Port(extraNewsItemCount: 24);
    await tester.binding.setSurfaceSize(const Size(900, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    final first = _focusNode(tester, 'library visibility item live-1');
    first.requestFocus();
    await tester.pump();
    for (var i = 0; i < 16; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library visibility item news-extra-14',
    );
    expect(
      find.byKey(const ValueKey('visibility-item-news-extra-14')),
      findsOneWidget,
    );
  });

  testWidgets(
    'Down on the last loaded item pages and focuses the first new row',
    (tester) async {
      final port = _Port(extraNewsItemCount: 2, pageChunkSize: 2);
      await tester.pumpWidget(app(port));
      await tester.pumpAndSettle();
      final lastLoaded = _focusNode(tester, 'library visibility item live-2');
      lastLoaded.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'library visibility item news-extra-0',
      );
      expect(
        find.byKey(const ValueKey('visibility-item-news-extra-0')),
        findsOneWidget,
      );
    },
  );

  testWidgets('repeated Down keeps next-page loading single-flight', (
    tester,
  ) async {
    final port = _PagingGatePort();
    await tester.pumpWidget(app(port));
    await tester.pumpAndSettle();
    _focusNode(tester, 'library visibility item live-2').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(port.nextPageCalls, 1);
    port.nextPage.complete(
      const LibraryVisibilityItemPage(
        items: [
          LibraryVisibilityItem(
            catalogItemId: 'paged-once',
            title: 'Paged Once',
            kind: SourceMediaKind.live,
            hidden: false,
          ),
        ],
        nextCursor: null,
      ),
    );
    await tester.pumpAndSettle();
    expect(port.nextPageCalls, 1);
    expect(find.text('Paged Once'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('visibility-item-paged-once')),
      findsOneWidget,
    );
  });

  testWidgets('virtual rows retain only bounded mounted focus nodes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(_Port(extraNewsItemCount: 220)));
    await tester.pumpAndSettle();
    final itemFocusCount = tester
        .widgetList<Focus>(find.byType(Focus))
        .where(
          (focus) =>
              focus.focusNode?.debugLabel?.startsWith(
                'library visibility item ',
              ) ??
              false,
        )
        .length;
    expect(itemFocusCount, lessThan(30));
  });

  testWidgets('A to B to A reset ignores the stale first A response', (
    tester,
  ) async {
    final port = _RacingPort();
    await tester.pumpWidget(app(port));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('visibility-category-sports')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('visibility-category-news')));
    await tester.pump();
    port.latestA.complete(
      const LibraryVisibilityItemPage(
        items: [
          LibraryVisibilityItem(
            catalogItemId: 'newest-a',
            title: 'Newest A',
            kind: SourceMediaKind.live,
            hidden: false,
          ),
        ],
        nextCursor: null,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Newest A'), findsOneWidget);
    port.firstA.complete(
      const LibraryVisibilityItemPage(
        items: [
          LibraryVisibilityItem(
            catalogItemId: 'stale-a',
            title: 'Stale A',
            kind: SourceMediaKind.live,
            hidden: false,
          ),
        ],
        nextCursor: null,
      ),
    );
    port.middleB.complete(
      const LibraryVisibilityItemPage(items: [], nextCursor: null),
    );
    await tester.pumpAndSettle();
    expect(find.text('Newest A'), findsOneWidget);
    expect(find.text('Stale A'), findsNothing);
  });

  testWidgets('item focus edge reserves two-pixel geometry in both states', (
    tester,
  ) async {
    await tester.pumpWidget(app(_Port()));
    await tester.pumpAndSettle();
    final finder = find.byKey(const ValueKey('visibility-item-live-1'));
    Border border() =>
        (tester.widget<Container>(finder).decoration! as BoxDecoration).border!
            as Border;
    expect(border().top.width, 2);
    final node = _focusNode(tester, 'library visibility item live-1');
    node.requestFocus();
    await tester.pump();
    expect(border().top.width, 2);
    expect(border().bottom.width, 2);
  });
}

FocusNode _focusNode(WidgetTester tester, String label) => tester
    .widgetList<Focus>(find.byType(Focus))
    .firstWhere((focus) => focus.focusNode?.debugLabel == label)
    .focusNode!;

class _Port implements LibraryVisibilityPort {
  _Port({
    this.categoryGate,
    this.extraCategoryCount = 0,
    this.extraNewsItemCount = 0,
    this.pageChunkSize,
    this.failItems = false,
  });
  final Completer<List<LibraryVisibilityCategory>>? categoryGate;
  final int extraCategoryCount;
  final int extraNewsItemCount;
  final int? pageChunkSize;
  bool failCategories = false;
  bool failItems;
  bool failBulk = false;
  bool failFilteredAfterBulk = false;
  bool bulkCommitted = false;
  int bulkWriteCalls = 0;
  int categoryLoadCalls = 0;
  int itemLoadCalls = 0;
  final List<(SourceMediaKind, String, bool)> categoryChanges = [];
  final List<(SourceMediaKind, bool)> bulkChanges = [];
  final List<(String, bool)> itemChanges = [];
  final Map<String, bool> categoriesHidden = {};
  final Map<String, bool> itemsHidden = {'movie-2': true};
  List<LibraryVisibilityCategory> get allCategories => [
    const LibraryVisibilityCategory(
      ref: LibraryVisibilityCategoryRef.group('news'),
      name: 'News',
      availableItemCount: 56712,
      hidden: false,
    ),
    const LibraryVisibilityCategory(
      ref: LibraryVisibilityCategoryRef.group('sports'),
      name: 'Sports',
      availableItemCount: 1,
      hidden: false,
    ),
    const LibraryVisibilityCategory(
      ref: LibraryVisibilityCategoryRef.group('film'),
      name: 'Film Select',
      availableItemCount: 2,
      hidden: false,
    ),
    const LibraryVisibilityCategory(
      ref: LibraryVisibilityCategoryRef.uncategorized(),
      name: 'Uncategorized',
      availableItemCount: 1,
      hidden: false,
    ),
    for (var i = 0; i < extraCategoryCount; i++)
      LibraryVisibilityCategory(
        ref: LibraryVisibilityCategoryRef.group('extra-$i'),
        name: 'Extra category $i',
        availableItemCount: 1,
        hidden: false,
      ),
  ];
  List<LibraryVisibilityItem> get items => [
    const LibraryVisibilityItem(
      catalogItemId: 'live-1',
      title: 'News One',
      kind: SourceMediaKind.live,
      hidden: false,
    ),
    const LibraryVisibilityItem(
      catalogItemId: 'live-2',
      title: 'News Two',
      kind: SourceMediaKind.live,
      hidden: false,
    ),
    for (var i = 0; i < extraNewsItemCount; i++)
      LibraryVisibilityItem(
        catalogItemId: 'news-extra-$i',
        title: 'News Extra $i',
        kind: SourceMediaKind.live,
        hidden: false,
      ),
    const LibraryVisibilityItem(
      catalogItemId: 'sport-1',
      title: 'Sports One',
      kind: SourceMediaKind.live,
      hidden: false,
    ),
    const LibraryVisibilityItem(
      catalogItemId: 'movie-2',
      title: 'Hidden Film',
      kind: SourceMediaKind.movies,
      hidden: true,
    ),
    const LibraryVisibilityItem(
      catalogItemId: 'loose-1',
      title: 'Loose Channel',
      kind: SourceMediaKind.live,
      hidden: false,
    ),
  ];
  @override
  Future<List<LibraryVisibilityCategory>> loadCategories({
    required String sourceId,
    required SourceMediaKind kind,
    required bool hiddenOnly,
  }) async {
    categoryLoadCalls++;
    if (categoryGate != null && !categoryGate!.isCompleted) {
      return categoryGate!.future;
    }
    if (failCategories ||
        (failFilteredAfterBulk && bulkCommitted && hiddenOnly)) {
      throw StateError('local');
    }
    final categoryRows = [
      for (final c in allCategories)
        LibraryVisibilityCategory(
          ref: c.ref,
          name: c.name,
          availableItemCount: c.availableItemCount,
          hidden: categoriesHidden[c.ref.sourceGroupId] ?? c.hidden,
        ),
    ];
    if (!hiddenOnly) {
      return categoryRows;
    }
    return categoryRows
        .where(
          (c) =>
              c.hidden ||
              _itemsFor(c.ref)
                  .any((i) => itemsHidden[i.catalogItemId] ?? i.hidden),
        )
        .toList();
  }

  List<LibraryVisibilityItem> _itemsFor(
    LibraryVisibilityCategoryRef ref,
  ) => switch (ref.sourceGroupId) {
    'news' =>
      items
          .where(
            (item) =>
                item.catalogItemId.startsWith('live-') ||
                item.catalogItemId.startsWith('news-extra-'),
          )
          .toList(),
    'sports' => items.where((item) => item.catalogItemId == 'sport-1').toList(),
    'film' => items.where((item) => item.catalogItemId == 'movie-2').toList(),
    null => items.where((item) => item.catalogItemId == 'loose-1').toList(),
    _ => const [],
  };
  @override
  Future<LibraryVisibilityItemPage> loadItems({
    required String sourceId,
    required SourceMediaKind kind,
    required LibraryVisibilityCategoryRef category,
    required bool hiddenOnly,
    String? cursor,
    int limit = 100,
  }) async {
    itemLoadCalls++;
    if (failItems) {
      throw StateError('items');
    }
    var result = [
      for (final item in _itemsFor(category))
        LibraryVisibilityItem(
          catalogItemId: item.catalogItemId,
          title: item.title,
          kind: item.kind,
          hidden: itemsHidden[item.catalogItemId] ?? item.hidden,
        ),
    ];
    if (hiddenOnly) {
      result = result.where((item) => item.hidden).toList();
    }
    final chunkSize = pageChunkSize;
    if (chunkSize == null) {
      return LibraryVisibilityItemPage(items: result, nextCursor: null);
    }
    final start = int.tryParse(cursor ?? '0') ?? 0;
    final end = start + chunkSize < result.length
        ? start + chunkSize
        : result.length;
    return LibraryVisibilityItemPage(
      items: result.sublist(start, end),
      nextCursor: end < result.length ? '$end' : null,
    );
  }

  @override
  Future<void> setCategoryHidden({
    required String sourceId,
    required SourceMediaKind kind,
    required LibraryVisibilityCategoryRef category,
    required bool hidden,
  }) async {
    categoriesHidden[category.sourceGroupId!] = hidden;
    categoryChanges.add((kind, category.sourceGroupId!, hidden));
  }

  @override
  Future<int> setAllCategoriesHidden({
    required String sourceId,
    required SourceMediaKind kind,
    required bool hidden,
  }) async {
    bulkWriteCalls++;
    if (failBulk) throw StateError('bulk');
    var changed = 0;
    for (final category in allCategories) {
      final id = category.ref.sourceGroupId;
      if (id == null) continue;
      final wasHidden = categoriesHidden[id] ?? category.hidden;
      if (wasHidden != hidden) changed++;
      categoriesHidden[id] = hidden;
    }
    bulkChanges.add((kind, hidden));
    bulkCommitted = true;
    return changed;
  }

  @override
  Future<void> setItemHidden({
    required String sourceId,
    required String catalogItemId,
    required bool hidden,
  }) async {
    itemsHidden[catalogItemId] = hidden;
    itemChanges.add((catalogItemId, hidden));
  }
}

class _BulkGatePort extends _Port {
  final pending = Completer<int>();

  @override
  Future<int> setAllCategoriesHidden({
    required String sourceId,
    required SourceMediaKind kind,
    required bool hidden,
  }) => pending.future;
}

class _CommittingBulkGatePort extends _Port {
  final pending = Completer<void>();

  @override
  Future<int> setAllCategoriesHidden({
    required String sourceId,
    required SourceMediaKind kind,
    required bool hidden,
  }) async {
    await pending.future;
    return super.setAllCategoriesHidden(
      sourceId: sourceId,
      kind: kind,
      hidden: hidden,
    );
  }
}

class _CategoryGatePort extends _Port {
  final pending = Completer<void>();

  @override
  Future<void> setCategoryHidden({
    required String sourceId,
    required SourceMediaKind kind,
    required LibraryVisibilityCategoryRef category,
    required bool hidden,
  }) async {
    await pending.future;
    await super.setCategoryHidden(
      sourceId: sourceId,
      kind: kind,
      category: category,
      hidden: hidden,
    );
  }
}

class _RacingPort extends _Port {
  final firstA = Completer<LibraryVisibilityItemPage>();
  final middleB = Completer<LibraryVisibilityItemPage>();
  final latestA = Completer<LibraryVisibilityItemPage>();
  int _calls = 0;

  @override
  Future<LibraryVisibilityItemPage> loadItems({
    required String sourceId,
    required SourceMediaKind kind,
    required LibraryVisibilityCategoryRef category,
    required bool hiddenOnly,
    String? cursor,
    int limit = 100,
  }) {
    _calls++;
    return switch (_calls) {
      1 => firstA.future,
      2 => middleB.future,
      3 => latestA.future,
      _ => super.loadItems(
        sourceId: sourceId,
        kind: kind,
        category: category,
        hiddenOnly: hiddenOnly,
        cursor: cursor,
        limit: limit,
      ),
    };
  }
}

class _InterleavingDirectoryPort extends _Port {
  final movies = Completer<List<LibraryVisibilityCategory>>();
  final series = Completer<List<LibraryVisibilityCategory>>();

  @override
  Future<List<LibraryVisibilityCategory>> loadCategories({
    required String sourceId,
    required SourceMediaKind kind,
    required bool hiddenOnly,
  }) => switch (kind) {
    SourceMediaKind.movies => movies.future,
    SourceMediaKind.series => series.future,
    SourceMediaKind.live => super.loadCategories(
      sourceId: sourceId,
      kind: kind,
      hiddenOnly: hiddenOnly,
    ),
  };
}

class _PagingGatePort extends _Port {
  _PagingGatePort() : super(extraNewsItemCount: 2, pageChunkSize: 2);

  final nextPage = Completer<LibraryVisibilityItemPage>();
  int nextPageCalls = 0;

  @override
  Future<LibraryVisibilityItemPage> loadItems({
    required String sourceId,
    required SourceMediaKind kind,
    required LibraryVisibilityCategoryRef category,
    required bool hiddenOnly,
    String? cursor,
    int limit = 100,
  }) {
    if (cursor != null) {
      nextPageCalls++;
      return nextPage.future;
    }
    return super.loadItems(
      sourceId: sourceId,
      kind: kind,
      category: category,
      hiddenOnly: hiddenOnly,
      cursor: cursor,
      limit: limit,
    );
  }
}
