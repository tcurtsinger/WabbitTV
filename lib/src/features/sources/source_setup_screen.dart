// THESIS: Source Ledger turns a private Xtream account into one calm local catalog task.
// OWN-WORLD: Quiet Broadcast keeps graphite structure, warm-white reading order, and one amber signal.
// STORY: Four credentials lead into a foreground import, then a ready handoff—not a provider dashboard.
// FIRST VIEWPORT: A centered form owns attention while three equal media stages hold operational truth below.
// FORM: Crisp 6–8 px edges, semantic controls, visible focus, and short state changes preserve desk-and-couch clarity.
// FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and DESIGN.md

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'source_models.dart';
import 'source_setup_controller.dart';
import 'xtream_connector.dart';

const _graphite = Color(0xFF111212);
const _surface = Color(0xFF191A1A);
const _raised = Color(0xFF222321);
const _line = Color(0xFF343534);
const _warmWhite = Color(0xFFF4F0E7);
const _quietText = Color(0xFFAAA8A2);
const _amber = Color(0xFFFFB347);
const _amberInk = Color(0xFF17120A);

class SourceSetupScreen extends StatefulWidget {
  const SourceSetupScreen({
    super.key,
    required this.initialFocus,
    required this.onContentFocus,
    required this.onExit,
    required this.onBrowse,
    this.controller,
  });

  final FocusNode initialFocus;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onExit;
  final ValueChanged<SourceMediaKind> onBrowse;
  final SourceSetupController? controller;

  @override
  State<SourceSetupScreen> createState() => _SourceSetupScreenState();
}

class _SourceSetupScreenState extends State<SourceSetupScreen> {
  late final SourceSetupController _controller =
      widget.controller ?? SourceSetupController();
  late final bool _ownsController = widget.controller == null;
  final _serverFocus = FocusNode(debugLabel: 'source server URL');
  final _usernameFocus = FocusNode(debugLabel: 'source username');
  final _passwordFocus = FocusNode(debugLabel: 'source password');
  final _visibilityFocus = FocusNode(debugLabel: 'source password visibility');
  final _connectFocus = FocusNode(debugLabel: 'source connect and import');
  final _cancelFocus = FocusNode(debugLabel: 'source cancel');
  late final Map<SourceMediaKind, FocusNode> _browseFocus = {
    for (final kind in SourceMediaKind.values)
      kind: FocusNode(debugLabel: 'browse ${kind.label}'),
  };
  bool _wasImporting = false;
  final _name = TextEditingController(text: 'My IPTV');
  final _server = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_refresh);
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _applyControllerFocus(),
    );
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    _controller.removeListener(_refresh);
    if (_ownsController) _controller.dispose();
    _serverFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _visibilityFocus.dispose();
    _connectFocus.dispose();
    _cancelFocus.dispose();
    for (final node in _browseFocus.values) {
      node.dispose();
    }
    _name.dispose();
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _applyControllerFocus(),
      );
    }
  }

  void _applyControllerFocus() {
    if (!mounted) return;
    if (_controller.ready != null) {
      _browseFocus[SourceMediaKind.live]!.requestFocus();
    } else if (_controller.isImporting) {
      _cancelFocus.requestFocus();
    } else if (_wasImporting) {
      widget.initialFocus.requestFocus();
    }
    _wasImporting = _controller.isImporting;
  }

  void _submit() {
    _controller.connect(
      name: _name.text,
      serverUrl: _server.text,
      username: _username.text,
      password: _password.text,
    );
  }

  void _handleBack() {
    if (_controller.isImporting) {
      _cancelFocus.requestFocus();
      return;
    }
    widget.onExit();
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        (event.logicalKey != LogicalKeyboardKey.escape &&
            event.logicalKey != LogicalKeyboardKey.browserBack)) {
      return false;
    }
    _handleBack();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: ColoredBox(
        color: _graphite,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 760;
              return Padding(
                padding: EdgeInsets.fromLTRB(
                  narrow ? 24 : 48,
                  22,
                  narrow ? 24 : 32,
                  narrow ? 24 : 34,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _SourceHeader(),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(vertical: 28),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: (constraints.maxHeight - 188).clamp(
                              280,
                              double.infinity,
                            ),
                          ),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 648),
                              child: _controller.ready == null
                                  ? _SourceForm(
                                      controller: _controller,
                                      name: _name,
                                      server: _server,
                                      username: _username,
                                      password: _password,
                                      nameFocus: widget.initialFocus,
                                      serverFocus: _serverFocus,
                                      usernameFocus: _usernameFocus,
                                      passwordFocus: _passwordFocus,
                                      visibilityFocus: _visibilityFocus,
                                      connectFocus: _connectFocus,
                                      cancelFocus: _cancelFocus,
                                      showPassword: _showPassword,
                                      onShowPassword: () => setState(
                                        () => _showPassword = !_showPassword,
                                      ),
                                      onFocused: widget.onContentFocus,
                                      onSubmit: _submit,
                                      onCancel: _controller.isImporting
                                          ? _controller.cancel
                                          : widget.onExit,
                                    )
                                  : _SourceReady(
                                      ready: _controller.ready!,
                                      onBrowse: widget.onBrowse,
                                      onFocused: widget.onContentFocus,
                                      focusNodes: _browseFocus,
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    _StageDock(
                      stages: _controller.stages,
                      counts: _controller.ready?.counts,
                      narrow: narrow,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SourceHeader extends StatelessWidget {
  const _SourceHeader();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Add source',
          style: TextStyle(
            color: _warmWhite,
            fontSize: 31,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.7,
          ),
        ),
        SizedBox(height: 6),
        Text(
          'Connect an Xtream account to build your local library.',
          style: TextStyle(color: _quietText, fontSize: 16, height: 1.45),
        ),
      ],
    );
  }
}

class _SourceForm extends StatelessWidget {
  const _SourceForm({
    required this.controller,
    required this.name,
    required this.server,
    required this.username,
    required this.password,
    required this.nameFocus,
    required this.serverFocus,
    required this.usernameFocus,
    required this.passwordFocus,
    required this.visibilityFocus,
    required this.connectFocus,
    required this.cancelFocus,
    required this.showPassword,
    required this.onShowPassword,
    required this.onFocused,
    required this.onSubmit,
    required this.onCancel,
  });

  final SourceSetupController controller;
  final TextEditingController name;
  final TextEditingController server;
  final TextEditingController username;
  final TextEditingController password;
  final FocusNode nameFocus;
  final FocusNode serverFocus;
  final FocusNode usernameFocus;
  final FocusNode passwordFocus;
  final FocusNode visibilityFocus;
  final FocusNode connectFocus;
  final FocusNode cancelFocus;
  final bool showPassword;
  final VoidCallback onShowPassword;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onSubmit;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final errors = controller.fieldErrors;
    final disabled = controller.isImporting;
    return DecoratedBox(
      decoration: const BoxDecoration(),
      child: Padding(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              controller.isImporting
                  ? 'Importing your library'
                  : 'Source details',
              style: const TextStyle(
                color: _warmWhite,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              controller.isImporting
                  ? 'This stays in the foreground until it finishes or you cancel.'
                  : 'Your account credentials are stored by Windows after the import succeeds.',
              style: const TextStyle(
                color: _quietText,
                fontSize: 14,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            _Field(
              label: 'Source name',
              controller: name,
              focusNode: nameFocus,
              errorText: errors['name'],
              enabled: !disabled,
              autofocus: true,
              onFocused: onFocused,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 14),
            _Field(
              label: 'Server URL',
              hint: 'https://provider.example:port',
              controller: server,
              focusNode: serverFocus,
              errorText: errors['serverUrl'],
              enabled: !disabled,
              onFocused: onFocused,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 14),
            _Field(
              label: 'Username',
              controller: username,
              focusNode: usernameFocus,
              errorText: errors['username'],
              enabled: !disabled,
              onFocused: onFocused,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 14),
            _Field(
              label: 'Password',
              controller: password,
              focusNode: passwordFocus,
              errorText: errors['password'],
              enabled: !disabled,
              onFocused: onFocused,
              obscureText: !showPassword,
              textInputAction: TextInputAction.done,
              suffix: IconButton(
                focusNode: visibilityFocus,
                tooltip: showPassword ? 'Hide password' : 'Show password',
                onPressed: disabled ? null : onShowPassword,
                icon: Icon(
                  showPassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
            ),
            if (controller.failure != null) ...[
              const SizedBox(height: 18),
              _FailureNotice(failure: controller.failure!),
            ],
            const SizedBox(height: 24),
            FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: Row(
                children: [
                  FocusTraversalOrder(
                    order: const NumericFocusOrder(2),
                    child: _SourceButton(
                      label: 'Cancel',
                      focusNode: cancelFocus,
                      primary: false,
                      enabled: true,
                      onFocused: onFocused,
                      onPressed: onCancel,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FocusTraversalOrder(
                      order: const NumericFocusOrder(1),
                      child: _SourceButton(
                        label: 'Connect and import',
                        focusNode: connectFocus,
                        primary: true,
                        enabled: !disabled,
                        onFocused: onFocused,
                        onPressed: onSubmit,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.onFocused,
    this.hint,
    this.errorText,
    this.autofocus = false,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.suffix,
  });

  final String label;
  final String? hint;
  final String? errorText;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final bool autofocus;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Widget? suffix;
  final ValueChanged<FocusNode> onFocused;

  @override
  Widget build(BuildContext context) {
    return Focus(
      skipTraversal: true,
      onFocusChange: (focused) {
        if (focused) onFocused(focusNode);
      },
      child: TextField(
        key: ValueKey('source-field-$label'),
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        enabled: enabled,
        obscureText: obscureText,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        style: const TextStyle(color: _warmWhite, fontSize: 16),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          errorText: errorText,
          suffixIcon: suffix,
          filled: true,
          fillColor: _raised,
          labelStyle: const TextStyle(color: _quietText),
          hintStyle: const TextStyle(color: _quietText),
          errorStyle: const TextStyle(color: Color(0xFFFFC1B3)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: _line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: _amber, width: 2),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0xFFFFC1B3)),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: _amber, width: 2),
          ),
        ),
      ),
    );
  }
}

class _SourceButton extends StatelessWidget {
  const _SourceButton({
    required this.label,
    required this.focusNode,
    required this.primary,
    required this.enabled,
    required this.onFocused,
    required this.onPressed,
  });

  final String label;
  final FocusNode focusNode;
  final bool primary;
  final bool enabled;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Focus(
      skipTraversal: true,
      onFocusChange: (focused) {
        if (focused) onFocused(focusNode);
      },
      child: primary
          ? FilledButton(
              focusNode: focusNode,
              onPressed: enabled ? onPressed : null,
              style: FilledButton.styleFrom(
                backgroundColor: _amber,
                foregroundColor: _amberInk,
                disabledBackgroundColor: _raised,
                disabledForegroundColor: _quietText,
                minimumSize: const Size(0, 46),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              child: Text(label),
            )
          : OutlinedButton(
              focusNode: focusNode,
              onPressed: enabled ? onPressed : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: _warmWhite,
                disabledForegroundColor: _quietText,
                side: const BorderSide(color: _line),
                minimumSize: const Size(92, 46),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              child: Text(label),
            ),
    );
  }
}

class _FailureNotice extends StatelessWidget {
  const _FailureNotice({required this.failure});

  final SourceImportFailureKind failure;

  @override
  Widget build(BuildContext context) {
    final copy = switch (failure) {
      SourceImportFailureKind.authentication => 'We could not verify that account. Check the username and password, then try again.',
      SourceImportFailureKind.unreachable => 'Wabbit TV could not reach that provider. Check the server URL and your connection, then try again.',
      SourceImportFailureKind.emptyResponse => 'That provider did not return a usable catalog. Check the server URL and try again.',
      SourceImportFailureKind.tooLarge =>
        'That provider catalog is too large to import safely.',
      SourceImportFailureKind.timedOut => 'That provider took too long to respond. Check the connection and try again.',
      SourceImportFailureKind.cancelled => 'The import was cancelled.',
    };
    return Semantics(
      liveRegion: true,
      child: Text(
        copy,
        style: const TextStyle(
          color: Color(0xFFFFC1B3),
          fontSize: 14,
          height: 1.4,
        ),
      ),
    );
  }
}

class _SourceReady extends StatelessWidget {
  const _SourceReady({
    required this.ready,
    required this.onBrowse,
    required this.onFocused,
    required this.focusNodes,
  });

  final SourceReady ready;
  final ValueChanged<SourceMediaKind> onBrowse;
  final ValueChanged<FocusNode> onFocused;
  final Map<SourceMediaKind, FocusNode> focusNodes;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(),
      child: Padding(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Source ready',
              style: TextStyle(
                color: _warmWhite,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Your local catalog is ready to browse.',
              style: TextStyle(color: _quietText, fontSize: 16),
            ),
            const SizedBox(height: 22),
            for (final kind in SourceMediaKind.values) ...[
              _ReadyAction(
                kind: kind,
                count: ready.counts[kind] ?? 0,
                onBrowse: onBrowse,
                onFocused: onFocused,
                focusNode: focusNodes[kind]!,
              ),
              if (kind != SourceMediaKind.series) const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReadyAction extends StatelessWidget {
  const _ReadyAction({
    required this.kind,
    required this.count,
    required this.onBrowse,
    required this.onFocused,
    required this.focusNode,
  });

  final SourceMediaKind kind;
  final int count;
  final ValueChanged<SourceMediaKind> onBrowse;
  final ValueChanged<FocusNode> onFocused;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    return Focus(
      skipTraversal: true,
      onFocusChange: (focused) {
        if (focused) onFocused(focusNode);
      },
      child: OutlinedButton(
        focusNode: focusNode,
        onPressed: () => onBrowse(kind),
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          foregroundColor: _warmWhite,
          side: const BorderSide(color: _line),
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        child: Row(
          children: [
            Expanded(child: Text('Browse ${kind.label}')),
            Text(
              '${_formatCount(count)} items',
              style: const TextStyle(color: _quietText),
            ),
          ],
        ),
      ),
    );
  }
}

class _StageDock extends StatelessWidget {
  const _StageDock({
    required this.stages,
    required this.counts,
    required this.narrow,
  });

  final Map<SourceMediaKind, ImportStageStatus> stages;
  final Map<SourceMediaKind, int>? counts;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final cells = [
      for (final kind in SourceMediaKind.values)
        _StageCell(kind: kind, status: stages[kind]!, count: counts?[kind]),
    ];
    return DecoratedBox(
      key: const ValueKey('source-stage-dock'),
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: narrow
          ? Column(
              children: [
                for (var index = 0; index < cells.length; index++) ...[
                  cells[index],
                  if (index < cells.length - 1)
                    const Divider(height: 1, color: _line),
                ],
              ],
            )
          : IntrinsicHeight(
              child: Row(
                children: [
                  for (var index = 0; index < cells.length; index++) ...[
                    Expanded(child: cells[index]),
                    if (index < cells.length - 1)
                      const VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: _line,
                      ),
                  ],
                ],
              ),
            ),
    );
  }
}

String _formatCount(int value) => value.toString().replaceAllMapped(
  RegExp(r'(?<!^)(?=(?:\d{3})+$)'),
  (_) => ',',
);

class _StageCell extends StatelessWidget {
  const _StageCell({required this.kind, required this.status, this.count});

  final SourceMediaKind kind;
  final ImportStageStatus status;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final active = status == ImportStageStatus.importing;
    final icon = switch (status) {
      ImportStageStatus.waiting => Icons.schedule_outlined,
      ImportStageStatus.importing => Icons.downloading_outlined,
      ImportStageStatus.complete => Icons.check_circle_outline,
      ImportStageStatus.error => Icons.error_outline,
    };
    final label = switch (status) {
      ImportStageStatus.waiting => 'Waiting',
      ImportStageStatus.importing => 'Importing',
      ImportStageStatus.complete =>
        count == null ? 'Complete' : '${_formatCount(count!)} items',
      ImportStageStatus.error => 'Error',
    };
    return Semantics(
      key: ValueKey('source-stage-cell-${kind.name}'),
      label: '${kind.label}: $label',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Row(
          children: [
            Icon(icon, color: active ? _amber : _quietText, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                kind.label,
                style: const TextStyle(
                  color: _warmWhite,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              label,
              style: TextStyle(
                color: active ? _amber : _quietText,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
