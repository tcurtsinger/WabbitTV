import 'package:flutter/widgets.dart';

/// The focus node the shell hands from screen to screen as each one's first
/// content target.
///
/// A [Focus] without its own key handler reports its node's current one
/// (`Focus.onKeyEvent` falls back to `focusNode.onKeyEvent`) and passes it
/// back into [attach], so a shared node kept the previous screen's handler:
/// a Sources row ran Browse's row handler, the arrows did nothing and Select
/// played a channel. Each attachment here keeps only the attaching widget's
/// own handler. (The shell resets `canRequestFocus` on each destination
/// change; screens such as Guide reuse the node and toggle it themselves.)
///
/// Flutter's focus guide says not to share one FocusNode between widgets;
/// this keeps the shell's existing shared node safe until screens own their
/// first targets.
class ContentFocusNode extends FocusNode {
  ContentFocusNode({super.debugLabel});

  @override
  FocusAttachment attach(
    BuildContext? context, {
    FocusOnKeyEventCallback? onKeyEvent,
    // ignore: deprecated_member_use
    FocusOnKeyCallback? onKey,
  }) {
    this.onKeyEvent = null;
    // ignore: deprecated_member_use
    this.onKey = null;
    // With the node's handlers cleared, a Focus reports only its own.
    final widget = context?.widget;
    return super.attach(
      context,
      onKeyEvent: widget is Focus ? widget.onKeyEvent : onKeyEvent,
      // ignore: deprecated_member_use
      onKey: widget is Focus ? widget.onKey : onKey,
    );
  }
}
