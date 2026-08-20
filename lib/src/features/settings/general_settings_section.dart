import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sources/startup_models.dart';
import 'startup_preferences_controller.dart';

const _surface = Color(0xFF191A1A);
const _raised = Color(0xFF222321);
const _line = Color(0xFF343534);
const _warmWhite = Color(0xFFF4F0E7);
const _quietText = Color(0xFFAAA8A2);
const _amber = Color(0xFFFFB347);

/// App-level settings that remain separate from every source-specific ledger.
class GeneralSettingsSection extends StatefulWidget {
  const GeneralSettingsSection({
    super.key,
    required this.controller,
    required this.onContentFocus,
    this.onMoveToSources,
  });

  final StartupPreferencesController controller;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback? onMoveToSources;

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
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _surface,
          border: Border.all(color: _line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'General',
                style: TextStyle(
                  color: _warmWhite,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Start Wabbit on',
                style: TextStyle(color: _quietText, fontSize: 15),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final target in StartupTarget.values)
                    _StartupChoice(
                      key: ValueKey('startup-choice-${target.name}'),
                      label: _label(target),
                      selected: controller.displayedTarget == target,
                      focusNode: _choices[target]!,
                      onMoveLeft: () => _moveChoice(target, -1),
                      onMoveRight: () => _moveChoice(target, 1),
                      onMoveDown: widget.onMoveToSources,
                      onPressed: busy
                          ? null
                          : () => unawaited(controller.setTarget(target)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'If the previous screen or channel is unavailable, Wabbit opens Home.',
                style: TextStyle(color: _quietText, fontSize: 14, height: 1.35),
              ),
              if (status != null) ...[
                const SizedBox(height: 10),
                Text(
                  status,
                  key: const ValueKey('startup-settings-status'),
                  style: TextStyle(
                    color: failed ? _warmWhite : _quietText,
                    fontSize: 14,
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
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _warmWhite,
                    side: const BorderSide(color: _line),
                    minimumSize: const Size(0, 44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  child: const Text('Retry'),
                ),
              ],
            ],
          ),
        ),
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
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final FocusNode focusNode;
  final VoidCallback onMoveLeft;
  final VoidCallback onMoveRight;
  final VoidCallback? onMoveDown;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final choice = FocusableActionDetector(
      focusNode: focusNode,
      enabled: onPressed != null,
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.arrowLeft): _MoveStartupChoiceIntent(
          -1,
        ),
        SingleActivator(LogicalKeyboardKey.arrowRight):
            _MoveStartupChoiceIntent(1),
        SingleActivator(LogicalKeyboardKey.arrowDown): _MoveToSourcesIntent(),
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
      },
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return Semantics(
            button: true,
            selected: selected,
            label: '$label startup choice',
            child: Material(
              color: selected ? _raised : Colors.transparent,
              shape: RoundedRectangleBorder(
                side: BorderSide(
                  color: focused
                      ? _amber
                      : selected
                      ? _quietText
                      : _line,
                  width: focused ? 2 : 1,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onPressed == null
                    ? null
                    : () {
                        focusNode.requestFocus();
                        onPressed!();
                      },
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 148,
                    minHeight: 48,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Center(
                      widthFactor: 1,
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: onPressed == null ? _quietText : _warmWhite,
                          fontSize: 14,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
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
