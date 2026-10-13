import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../cinema.dart';
import '../artwork/artwork_loader.dart';
import '../artwork/source_artwork.dart';
import '../sources/source_models.dart';
import 'playback_handoff.dart';

const _raised = Color(0xFF1E1E23);

class ContinuationFailureView extends StatelessWidget {
  const ContinuationFailureView({
    super.key,
    required this.title,
    required this.failure,
    required this.onRetry,
    required this.onBack,
  });
  final String title;
  final ContinuationFailure failure;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => _ContinuationFrame(
    title: title,
    onBack: onBack,
    child: _FailureMessage(
      message: failure.message,
      copyKey: const ValueKey('continuation-error-copy'),
      retryKey: const ValueKey('continuation-retry'),
      onRetry: onRetry,
    ),
  );
}

class MovieContinuation extends StatelessWidget {
  const MovieContinuation({
    super.key,
    required this.title,
    required this.onPlay,
    required this.onBack,
    this.artworkLocator,
    this.artworkLoader,
    this.onOrganize,
  });
  final String title;
  final VoidCallback onPlay;
  final VoidCallback onBack;
  final String? artworkLocator;
  final ArtworkProvider? artworkLoader;
  final VoidCallback? onOrganize;

  @override
  Widget build(BuildContext context) => _ContinuationFrame(
    title: title,
    overline: 'MOVIE',
    artwork: _Poster(
      key: const ValueKey('movie-continuation-artwork'),
      title: title,
      locator: artworkLocator,
      kind: SourceMediaKind.movies,
      loader: artworkLoader,
    ),
    onBack: onBack,
    onOrganize: onOrganize,
    leadingAction: _ContinuationAction(
      key: const ValueKey('movie-play'),
      label: 'Play',
      icon: Icons.play_arrow_rounded,
      primary: true,
      autofocus: true,
      onPressed: onPlay,
    ),
  );
}

class SeriesContinuation extends StatefulWidget {
  const SeriesContinuation({
    super.key,
    required this.title,
    required this.loading,
    required this.info,
    required this.failure,
    required this.onRetry,
    required this.onBack,
    required this.onEpisodeActivated,
    this.artworkLocator,
    this.artworkLoader,
    this.onOrganize,
  });
  final String title;
  final bool loading;
  final SeriesInfo? info;
  final ContinuationFailure? failure;
  final VoidCallback onRetry;
  final VoidCallback onBack;
  final ValueChanged<SeriesEpisode> onEpisodeActivated;
  final String? artworkLocator;
  final ArtworkProvider? artworkLoader;
  final VoidCallback? onOrganize;

  @override
  State<SeriesContinuation> createState() => _SeriesContinuationState();
}

class _SeriesContinuationState extends State<SeriesContinuation> {
  static const _episodeExtent = 52.0;

  int _season = 0;
  final _episodesScroll = ScrollController();
  final Map<int, FocusNode> _seasonNodes = {};
  final Map<int, FocusNode> _mountedEpisodeNodes = {};
  FocusNode _seasonFocus(int index) => _seasonNodes.putIfAbsent(
    index,
    () => FocusNode(debugLabel: 'series season $index'),
  );

  void _mountEpisodeNode(int index, FocusNode node) =>
      _mountedEpisodeNodes[index] = node;

  void _unmountEpisodeNode(int index, FocusNode node) {
    if (identical(_mountedEpisodeNodes[index], node)) {
      _mountedEpisodeNodes.remove(index);
    }
  }

  Widget get _artwork => _Poster(
    key: const ValueKey('series-continuation-artwork'),
    title: widget.title,
    locator: widget.artworkLocator,
    kind: SourceMediaKind.series,
    loader: widget.artworkLoader,
  );

  @override
  void didUpdateWidget(covariant SeriesContinuation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.info != oldWidget.info) _season = 0;
  }

  @override
  void dispose() {
    _episodesScroll.dispose();
    for (final node in _seasonNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _focusEpisode(int index) {
    void revealThenFocus() {
      if (!mounted || !_episodesScroll.hasClients) return;
      final position = _episodesScroll.position;
      const rowExtent = _episodeExtent;
      final rowStart = index * rowExtent;
      final rowEnd = rowStart + rowExtent;
      final visibleStart = _episodesScroll.offset;
      final visibleEnd = visibleStart + position.viewportDimension;
      final node = _mountedEpisodeNodes[index];
      if (rowStart >= visibleStart && rowEnd <= visibleEnd) {
        node?.requestFocus();
        return;
      }
      final target = (rowStart - (position.viewportDimension - rowExtent) / 2)
          .clamp(0.0, position.maxScrollExtent);
      _episodesScroll.jumpTo(target);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _mountedEpisodeNodes[index]?.requestFocus();
      });
    }

    if (_episodesScroll.hasClients) {
      revealThenFocus();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => revealThenFocus());
    }
  }

  @override
  Widget build(BuildContext context) {
    _ContinuationFrame frame({
      required Widget child,
      bool autofocusFrame = false,
      bool expandChild = false,
    }) => _ContinuationFrame(
      title: widget.title,
      overline: 'SERIES',
      artwork: _artwork,
      onBack: widget.onBack,
      onOrganize: widget.onOrganize,
      autofocusFrame: autofocusFrame,
      expandChild: expandChild,
      child: child,
    );

    if (widget.failure != null) {
      return frame(
        child: _FailureMessage(
          message: widget.failure!.message,
          copyKey: const ValueKey('series-error-copy'),
          retryKey: const ValueKey('series-retry'),
          onRetry: widget.onRetry,
        ),
      );
    }
    if (widget.loading || widget.info == null) {
      return frame(
        autofocusFrame: true,
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Cinema.amber,
              ),
            ),
            SizedBox(width: 12),
            Text(
              'Loading episodes…',
              style: TextStyle(color: Cinema.quiet, fontSize: 15),
            ),
          ],
        ),
      );
    }
    final seasons = widget.info!.seasons;
    if (seasons.isEmpty) {
      return frame(
        autofocusFrame: true,
        child: const Text(
          'This series has no episodes.',
          style: TextStyle(color: Cinema.quiet, fontSize: 15),
        ),
      );
    }
    final selected = seasons[_season.clamp(0, seasons.length - 1)];
    return frame(
      expandChild: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 52,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              // Room for the focus glow around the first and last season.
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                children: [
                  for (var index = 0; index < seasons.length; index++) ...[
                    if (index > 0) const SizedBox(width: 8),
                    _ContinuationAction(
                      key: ValueKey('series-season-${seasons[index].name}'),
                      label: 'Season ${seasons[index].name}',
                      selected: index == _season,
                      focusNode: _seasonFocus(index),
                      autofocus: index == 0,
                      ensureVisibleOnFocus: true,
                      onDown: selected.episodes.isEmpty
                          ? null
                          : () => _mountedEpisodeNodes[0]?.requestFocus(),
                      onPressed: () => setState(() => _season = index),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('series-episodes'),
              controller: _episodesScroll,
              itemExtent: _episodeExtent,
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: selected.episodes.length,
              itemBuilder: (context, index) {
                final episode = selected.episodes[index];
                return _EpisodeRow(
                  key: ValueKey('series-episode-$index'),
                  episode: episode,
                  label: episodeLabel(episode.title, widget.title),
                  index: index,
                  onNodeMounted: _mountEpisodeNode,
                  onNodeUnmounted: _unmountEpisodeNode,
                  onUp: index == 0
                      ? () => _seasonFocus(_season).requestFocus()
                      : () => _focusEpisode(index - 1),
                  onDown: index + 1 < selected.episodes.length
                      ? () => _focusEpisode(index + 1)
                      : null,
                  onPressed: () => widget.onEpisodeActivated(episode),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A 2:3 poster; without art it shows the title, as in the poster wall.
class _Poster extends StatelessWidget {
  const _Poster({
    super.key,
    required this.title,
    required this.locator,
    required this.kind,
    required this.loader,
  });

  final String title;
  final String? locator;
  final SourceMediaKind kind;
  final ArtworkProvider? loader;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: SourceArtwork(
      locator: locator,
      kind: kind,
      loader: loader,
      explicitlyActivated: true,
      width: double.infinity,
      height: double.infinity,
      placeholder: Padding(
        padding: const EdgeInsets.all(14),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Text(
            title,
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Cinema.quiet,
              fontFamily: Cinema.display,
              fontSize: 18,
              fontWeight: FontWeight.w800,
              height: 1.05,
            ),
          ),
        ),
      ),
    ),
  );
}

class _FailureMessage extends StatelessWidget {
  const _FailureMessage({
    required this.message,
    required this.copyKey,
    required this.retryKey,
    required this.onRetry,
  });

  final String message;
  final Key copyKey;
  final Key retryKey;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        message,
        key: copyKey,
        style: const TextStyle(color: Cinema.quiet, fontSize: 15, height: 1.4),
      ),
      const SizedBox(height: 18),
      _ContinuationAction(
        key: retryKey,
        label: 'Try again',
        primary: true,
        autofocus: true,
        onPressed: onRetry,
      ),
    ],
  );
}

/// Poster on the left, details on the right, a round Back button above.
class _ContinuationFrame extends StatelessWidget {
  const _ContinuationFrame({
    required this.title,
    required this.onBack,
    this.child,
    this.overline,
    this.artwork,
    this.leadingAction,
    this.autofocusFrame = false,
    this.expandChild = false,
    this.onOrganize,
  });
  final String title;
  final VoidCallback onBack;
  final Widget? child;
  final String? overline;
  final Widget? artwork;
  final Widget? leadingAction;
  final bool autofocusFrame;
  final bool expandChild;
  final VoidCallback? onOrganize;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Cinema.ink,
    child: Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.escape ||
                event.logicalKey == LogicalKeyboardKey.browserBack)) {
          onBack();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: SafeArea(
          left: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 32, 0),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final showPoster =
                    artwork != null && constraints.maxWidth >= 520;
                final posterWidth = (constraints.maxWidth * 0.26).clamp(
                  120.0,
                  220.0,
                );
                final actions = [
                  ?leadingAction,
                  if (onOrganize != null)
                    _ContinuationAction(
                      key: const ValueKey('continuation-organize'),
                      label: 'Organize',
                      icon: Icons.bookmark_add_outlined,
                      onPressed: onOrganize!,
                    ),
                ];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ContinuationAction(
                      key: const ValueKey('continuation-visible-back'),
                      label: 'Back',
                      icon: Icons.arrow_back_rounded,
                      round: true,
                      autofocus: autofocusFrame,
                      onPressed: onBack,
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (showPoster) ...[
                            SizedBox(
                              width: posterWidth,
                              height: posterWidth * 1.5,
                              child: artwork,
                            ),
                            const SizedBox(width: 32),
                          ],
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (overline != null) ...[
                                  Text(
                                    overline!,
                                    style: const TextStyle(
                                      color: Cinema.amber,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 1.5,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                ],
                                Text(
                                  title,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Cinema.text,
                                    fontFamily: Cinema.display,
                                    fontSize: 30,
                                    fontWeight: FontWeight.w800,
                                    height: 1.08,
                                    letterSpacing: -0.5,
                                  ),
                                ),
                                if (actions.isNotEmpty) ...[
                                  const SizedBox(height: 20),
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 10,
                                    children: actions,
                                  ),
                                ],
                                if (child != null) ...[
                                  const SizedBox(height: 22),
                                  if (expandChild)
                                    Expanded(child: child!)
                                  else
                                    child!,
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}

/// Providers often repeat the series title in every episode title; the row
/// drops that prefix so "Show - S01E01 - Pilot" reads "S01E01 - Pilot".
@visibleForTesting
String episodeLabel(String episode, String series) {
  if (series.isEmpty || !episode.startsWith(series)) return episode;
  final rest = episode.substring(series.length);
  final separator = RegExp(r'^[\s\-–—:|·]+').firstMatch(rest);
  if (separator == null || separator.end == rest.length) return episode;
  return rest.substring(separator.end);
}

class _EpisodeRow extends StatefulWidget {
  const _EpisodeRow({
    super.key,
    required this.episode,
    required this.label,
    required this.index,
    required this.onNodeMounted,
    required this.onNodeUnmounted,
    required this.onPressed,
    this.onUp,
    this.onDown,
  });
  final SeriesEpisode episode;
  final String label;
  final int index;
  final void Function(int index, FocusNode node) onNodeMounted;
  final void Function(int index, FocusNode node) onNodeUnmounted;
  final VoidCallback onPressed;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  @override
  State<_EpisodeRow> createState() => _EpisodeRowState();
}

class _EpisodeRowState extends State<_EpisodeRow> {
  bool _focused = false;
  bool _hovered = false;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'series episode ${widget.index}');
    widget.onNodeMounted(widget.index, _focusNode);
  }

  @override
  void didUpdateWidget(covariant _EpisodeRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      oldWidget.onNodeUnmounted(oldWidget.index, _focusNode);
      widget.onNodeMounted(widget.index, _focusNode);
    }
  }

  @override
  void dispose() {
    widget.onNodeUnmounted(widget.index, _focusNode);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focusNode,
    onFocusChange: (value) => setState(() => _focused = value),
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
          widget.onUp != null) {
        widget.onUp!();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
          widget.onDown != null) {
        widget.onDown!();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.select) {
        widget.onPressed();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Semantics(
      button: true,
      label: widget.episode.title,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: () {
            _focusNode.requestFocus();
            widget.onPressed();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              // Opaque when focused so the ring stays a ring.
              color: _focused
                  ? _raised
                  : _hovered
                  ? Cinema.glass
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(12),
              boxShadow: _focused ? Cinema.focusGlow : const [],
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 34,
                  child: Text(
                    '${widget.index + 1}',
                    style: TextStyle(
                      color: _focused ? Cinema.amber : Cinema.faint,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Cinema.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_focused)
                  const Icon(
                    Icons.play_arrow_rounded,
                    size: 22,
                    color: Cinema.amber,
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// A pill (or, with [round], a circle) button. Primary is amber; focus
/// fills any button amber, since a ring would show through a glass fill.
class _ContinuationAction extends StatefulWidget {
  const _ContinuationAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.round = false,
    this.primary = false,
    this.selected = false,
    this.autofocus = false,
    this.focusNode,
    this.onDown,
    this.ensureVisibleOnFocus = false,
  });
  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool round;
  final bool primary;
  final bool selected;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback? onDown;
  final bool ensureVisibleOnFocus;
  @override
  State<_ContinuationAction> createState() => _ContinuationActionState();
}

class _ContinuationActionState extends State<_ContinuationAction> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final solid = widget.primary || _focused;
    final ink = solid
        ? Cinema.amberInk
        : widget.selected
        ? Cinema.amber
        : Cinema.text;
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (value) {
        setState(() => _focused = value);
        if (value && widget.ensureVisibleOnFocus) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Scrollable.ensureVisible(
                context,
                alignment: 0.5,
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOut,
              );
            }
          });
        }
      },
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
            widget.onDown != null) {
          widget.onDown!();
          return KeyEventResult.handled;
        }
        final direction = switch (event.logicalKey) {
          LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
          LogicalKeyboardKey.arrowRight => TraversalDirection.right,
          LogicalKeyboardKey.arrowUp => TraversalDirection.up,
          LogicalKeyboardKey.arrowDown => TraversalDirection.down,
          _ => null,
        };
        if (direction != null) {
          FocusScope.of(context).focusInDirection(direction);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.select) {
          widget.onPressed();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Semantics(
        button: true,
        selected: widget.selected,
        label: widget.label,
        excludeSemantics: widget.round,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: () {
              widget.focusNode?.requestFocus();
              widget.onPressed();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: 44,
              width: widget.round ? 44 : null,
              padding: widget.round
                  ? EdgeInsets.zero
                  : EdgeInsets.fromLTRB(
                      widget.icon == null ? 18 : 14,
                      0,
                      18,
                      0,
                    ),
              alignment: widget.round ? Alignment.center : null,
              decoration: BoxDecoration(
                color: solid
                    ? Cinema.amber
                    : _hovered
                    ? Cinema.glassFocused
                    : Cinema.glass,
                borderRadius: BorderRadius.circular(22),
                boxShadow: !_focused
                    ? const []
                    : widget.primary
                    ? Cinema.focusGlow
                    : [Cinema.focusGlow.last],
              ),
              child: widget.round
                  ? Icon(widget.icon, size: 20, color: ink)
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.icon != null) ...[
                          Icon(widget.icon, size: 20, color: ink),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          widget.label,
                          style: TextStyle(
                            color: ink,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
