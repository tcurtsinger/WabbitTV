import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../cinema.dart';
import '../sources/startup_models.dart';
import 'startup_preferences_controller.dart';

const _warmWhite = Cinema.text;
const _quietText = Cinema.faint;
const _amber = Cinema.amber;

/// App-level settings that remain separate from every source-specific ledger.
class GeneralSettingsSection extends StatefulWidget {
  const GeneralSettingsSection({
    super.key,
    required this.controller,
    required this.onContentFocus,
    this.onMoveToSources,
    this.onMoveAbove,
  });

  final StartupPreferencesController controller;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback? onMoveToSources;

  /// Up from a choice; without it, directional focus can skip the header
  /// above and land on the navigation rail.
  final VoidCallback? onMoveAbove;

  @override
  State<GeneralSettingsSection> createState() => GeneralSettingsSectionState();
}

class GeneralSettingsSectionState extends State<GeneralSettingsSection> {
  late final Map<StartupTarget, FocusNode> _choices = {
    for (final target in StartupTarget.values)
      target: FocusNode(debugLabel: 'startup ${target.name}'),
  };
  final _retryFocus = FocusNode(debugLabel: 'startup retry');
  FocusNode? _focusedTarget;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    for (final node in [..._choices.values, _retryFocus]) {
      node.addListener(() {
        if (node.hasFocus) {
          _focusedTarget = node;
          widget.onContentFocus(node);
        } else if (_focusedTarget == node) {
          _focusedTarget = null;
        }
      });
    }
    unawaited(widget.controller.initialize());
  }

  @override
  void didUpdateWidget(covariant GeneralSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_changed);
    widget.controller.addListener(_changed);
    unawaited(widget.controller.initialize());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    for (final node in _choices.values) {
      node.dispose();
    }
    _retryFocus.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final focused = _focusedTarget;
    setState(() {});
    if (focused == null || !focused.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _focusedTarget != focused || !focused.hasFocus) return;
      if (focused.context != null && focused.canRequestFocus) {
        focused.requestFocus();
      }
    });
  }

  /// Returns remote focus to the durable choice currently shown as selected.
  void focusSelectedChoice() {
    final target = _choices[widget.controller.displayedTarget]!;
    if (target.context == null || !target.canRequestFocus) return;
    target.requestFocus();
  }

  void _moveChoice(StartupTarget current, int direction) {
    final targets = StartupTarget.values;
    final index = targets.indexOf(current);
    final next = (index + direction).clamp(0, targets.length - 1);
    _choices[targets[next]]!.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final busy = controller.state == StartupPreferencesState.loading;
    final failed =
        controller.state == StartupPreferencesState.loadFailed ||
        controller.state == StartupPreferencesState.saveFailed;
    final status = switch (controller.state) {
      StartupPreferencesState.loading => 'Loading startup choice…',
      StartupPreferencesState.saving => 'Saving startup choice…',
      StartupPreferencesState.loadFailed ||
      StartupPreferencesState.saveFailed => controller.recovery,
      StartupPreferencesState.ready => null,
    };
    return Semantics(
      key: const ValueKey('general-startup-settings'),
      container: true,
      liveRegion: true,
      label: [
        'General settings. Start Wabbit on ${_label(controller.displayedTarget)}.',
        ?status,
      ].join(' '),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'General',
            style: TextStyle(
              color: _quietText,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Text(
                  'Start Wabbit on',
                  style: TextStyle(
                    color: _warmWhite,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (final target in StartupTarget.values)
                _StartupChoice(
                  key: ValueKey('startup-choice-${target.name}'),
                  label: _label(target),
                  selected: controller.displayedTarget == target,
                  focusNode: _choices[target]!,
                  onMoveLeft: () => _moveChoice(target, -1),
                  onMoveRight: () => _moveChoice(target, 1),
                  onMoveDown: widget.onMoveToSources,
                  onMoveUp: widget.onMoveAbove,
                  onPressed: busy
                      ? null
                      : () => unawaited(controller.setTarget(target)),
                ),
            ],
          ),
          // Saving is near-instant, so only a failure gets a visible line;
          // a flash of "Saving…" shoved the page down and back up.
          if (failed && status != null) ...[
            const SizedBox(height: 8),
            Text(
              status,
              key: const ValueKey('startup-settings-status'),
              style: TextStyle(
                color: failed ? _warmWhite : _quietText,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ],
          if (failed) ...[
            const SizedBox(height: 10),
            OutlinedButton(
              key: const ValueKey('startup-settings-retry'),
              focusNode: _retryFocus,
              onPressed: () => unawaited(controller.retry()),
              style: Cinema.pillButton(),
              child: const Text('Retry'),
            ),
          ],
        ],
      ),
    );
  }
}

String _label(StartupTarget target) => switch (target) {
  StartupTarget.home => 'Home',
  StartupTarget.previousScreen => 'Previous screen',
  StartupTarget.lastChannel => 'Last channel',
};

class _StartupChoice extends StatelessWidget {
  const _StartupChoice({
    super.key,
    required this.label,
    required this.selected,
    required this.focusNode,
    required this.onMoveLeft,
    required this.onMoveRight,
    required this.onMoveDown,
    required this.onMoveUp,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final FocusNode focusNode;
  final VoidCallback onMoveLeft;
  final VoidCallback onMoveRight;
  final VoidCallback? onMoveDown;
  final VoidCallback? onMoveUp;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final choice = FocusableActionDetector(
      focusNode: focusNode,
      enabled: onPressed != null,
      shortcuts: {
        const SingleActivator(LogicalKeyboardKey.enter): const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.select):
            const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
            const _MoveStartupChoiceIntent(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight):
            const _MoveStartupChoiceIntent(1),
        const SingleActivator(LogicalKeyboardKey.arrowDown):
            const _MoveToSourcesIntent(),
        if (onMoveUp != null)
          const SingleActivator(LogicalKeyboardKey.arrowUp):
              const _MoveAboveIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onPressed?.call();
            return null;
          },
        ),
        _MoveStartupChoiceIntent: CallbackAction<_MoveStartupChoiceIntent>(
          onInvoke: (intent) {
            (intent.direction < 0 ? onMoveLeft : onMoveRight)();
            return null;
          },
        ),
        _MoveToSourcesIntent: CallbackAction<_MoveToSourcesIntent>(
          onInvoke: (_) {
            onMoveDown?.call();
            return null;
          },
        ),
        _MoveAboveIntent: CallbackAction<_MoveAboveIntent>(
          onInvoke: (_) {
            onMoveUp?.call();
            return null;
          },
        ),
      },
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return Semantics(
            button: true,
            selected: selected,
            label: '$label startup choice',
            child: GestureDetector(
              onTap: onPressed == null
                  ? null
                  : () {
                      focusNode.requestFocus();
                      onPressed!();
                    },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                constraints: const BoxConstraints(minWidth: 96, minHeight: 40),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  // Focus fills the pill solid amber; the glow ring would
                  // show through the translucent rest fill.
                  color: focused ? _amber : Cinema.glass,
                  borderRadius: BorderRadius.circular(20),
                  // Every pill carries the border so choosing one never
                  // changes any pill's width.
                  border: Border.all(
                    color: selected && !focused
                        ? _amber
                        : const Color(0x00000000),
                    width: 1.5,
                  ),
                  boxShadow: focused ? [Cinema.focusGlow.last] : const [],
                ),
                // No checkmark: it widened the chosen pill and shifted
                // its neighbors whenever the choice moved.
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: focused
                            ? Cinema.amberInk
                            : onPressed == null
                            ? _quietText
                            : selected
                            ? _amber
                            : _warmWhite,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    return choice;
  }
}

class _MoveStartupChoiceIntent extends Intent {
  const _MoveStartupChoiceIntent(this.direction);

  final int direction;
}

class _MoveToSourcesIntent extends Intent {
  const _MoveToSourcesIntent();
}

class _MoveAboveIntent extends Intent {
  const _MoveAboveIntent();
}
