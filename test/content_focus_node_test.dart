import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/content_focus_node.dart';

void main() {
  testWidgets('a reattached node runs only its current widget handler', (
    tester,
  ) async {
    final node = ContentFocusNode(debugLabel: 'shared');
    addTearDown(node.dispose);
    var previousScreenKeys = 0;

    // Screen A attaches the shared node with a key handler...
    await tester.pumpWidget(
      MaterialApp(
        home: Focus(
          key: const ValueKey('screen-a'),
          focusNode: node,
          onKeyEvent: (_, _) {
            previousScreenKeys++;
            return KeyEventResult.handled;
          },
          child: const SizedBox(),
        ),
      ),
    );
    // ...then screen B attaches it with none, as a FocusableActionDetector
    // or button does.
    var screenBActivations = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Shortcuts(
          key: const ValueKey('screen-b'),
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.arrowUp): ActivateIntent(),
          },
          child: Actions(
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) => screenBActivations++,
              ),
            },
            child: Focus(focusNode: node, child: const SizedBox()),
          ),
        ),
      ),
    );
    node.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);

    expect(previousScreenKeys, 0);
    expect(screenBActivations, 1);

    // A screen that brings its own handler still gets it.
    var screenCKeys = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Focus(
          key: const ValueKey('screen-c'),
          focusNode: node,
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent) screenCKeys++;
            return KeyEventResult.handled;
          },
          child: const SizedBox(),
        ),
      ),
    );
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(screenCKeys, 1);
    expect(screenBActivations, 1);
  });
}
