import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../artwork/artwork_loader.dart';
import '../artwork/source_artwork.dart';
import '../sources/source_models.dart';
import 'playback_handoff.dart';

const _graphite = Color(0xFF111212);
const _surface = Color(0xFF191A1A);
const _raised = Color(0xFF222321);
const _line = Color(0xFF343534);
const _warmWhite = Color(0xFFF4F0E7);
const _quietText = Color(0xFFAAA8A2);
const _amber = Color(0xFFFFB347);

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
    icon: Icons.error_outline,
    onBack: onBack,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          failure.message,
          key: const ValueKey('continuation-error-copy'),
          style: const TextStyle(color: _quietText, fontSize: 16, height: 1.4),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _ContinuationAction(
              key: const ValueKey('continuation-retry'),
              label: 'Retry',
              primary: true,
              autofocus: true,
              onPressed: onRetry,
            ),
          ],
        ),
      ],
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
    icon: Icons.movie_outlined,
    artwork: SourceArtwork(
      key: const ValueKey('movie-continuation-artwork'),
      locator: artworkLocator,
      kind: SourceMediaKind.movies,
      loader: artworkLoader,
      explicitlyActivated: true,
      width: 120,
      height: 84,
    ),
    onBack: onBack,
    onOrganize: onOrganize,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ContinuationAction(
          key: const ValueKey('movie-play'),
          label: 'Play',
          primary: true,
          autofocus: true,
          onPressed: onPlay,
        ),
      ],
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

  Widget get _artwork => SourceArtwork(
    key: const ValueKey('series-continuation-artwork'),
    locator: widget.artworkLocator,
    kind: SourceMediaKind.series,
    loader: widget.artworkLoader,
    explicitlyActivated: true,
    width: 120,
    height: 84,
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
      const rowExtent = 52.0;
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
    if (widget.failure != null) {
      return _ContinuationFrame(
        title: widget.title,
        icon: Icons.tv_outlined,
        artwork: _artwork,
        onBack: widget.onBack,
        onOrganize: widget.onOrganize,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.failure!.message,
              key: const ValueKey('series-error-copy'),
              style: const TextStyle(
                color: _quietText,
                fontSize: 16,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _ContinuationAction(
                  key: const ValueKey('series-retry'),
                  label: 'Retry',
                  primary: true,
                  autofocus: true,
                  onPressed: widget.onRetry,
                ),
              ],
            ),
          ],
        ),
      );
    }
    if (widget.loading || widget.info == null) {
      return _ContinuationFrame(
        title: widget.title,
        icon: Icons.tv_outlined,
        artwork: _artwork,
        onBack: widget.onBack,
        onOrganize: widget.onOrganize,
        autofocusFrame: true,
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text(
              'Loading episodes…',
              style: TextStyle(color: _quietText, fontSize: 16),
            ),
          ],
        ),
      );
    }
    final seasons = widget.info!.seasons;
    if (seasons.isEmpty) {
      return _ContinuationFrame(
        title: widget.title,
        icon: Icons.tv_outlined,
        artwork: _artwork,
        onBack: widget.onBack,
        onOrganize: widget.onOrganize,
        autofocusFrame: true,
        child: const Text(
          'No episodes are available for this series.',
          style: TextStyle(color: _quietText, fontSize: 16),
        ),
      );
    }
    final selected = seasons[_season.clamp(0, seasons.length - 1)];
    return _ContinuationFrame(
      title: widget.title,
      icon: Icons.tv_outlined,
      artwork: _artwork,
      onBack: widget.onBack,
      onOrganize: widget.onOrganize,
      expandChild: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 42,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
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
          const SizedBox(height: 16),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('series-episodes'),
              controller: _episodesScroll,
              itemExtent: 52,
              itemCount: selected.episodes.length,
              itemBuilder: (context, index) {
                final episode = selected.episodes[index];
                return _EpisodeRow(
                  key: ValueKey('series-episode-$index'),
                  episode: episode,
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

class _ContinuationFrame extends StatelessWidget {
  const _ContinuationFrame({
    required this.title,
    required this.icon,
    required this.onBack,
    required this.child,
    this.artwork,
    this.autofocusFrame = false,
    this.expandChild = false,
    this.onOrganize,
  });
  final String title;
  final IconData icon;
  final VoidCallback onBack;
  final Widget child;
  final Widget? artwork;
  final bool autofocusFrame;
  final bool expandChild;
  final VoidCallback? onOrganize;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: _graphite,
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
            padding: const EdgeInsets.fromLTRB(32, 22, 32, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 780),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      artwork ?? Icon(icon, size: 44, color: _quietText),
                      const Spacer(),
                      if (onOrganize != null) ...[
                        _ContinuationAction(
                          key: const ValueKey('continuation-organize'),
                          label: 'Organize',
                          onPressed: onOrganize!,
                        ),
                        const SizedBox(width: 10),
                      ],
                      _ContinuationAction(
                        key: const ValueKey('continuation-visible-back'),
                        label: 'Back',
                        autofocus: autofocusFrame,
                        onPressed: onBack,
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _warmWhite,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (expandChild)
                    Expanded(child: child)
                  else
                    Align(alignment: Alignment.topLeft, child: child),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _EpisodeRow extends StatefulWidget {
  const _EpisodeRow({
    super.key,
    required this.episode,
    required this.index,
    required this.onNodeMounted,
    required this.onNodeUnmounted,
    required this.onPressed,
    this.onUp,
    this.onDown,
  });
  final SeriesEpisode episode;
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
      child: GestureDetector(
        onTap: () {
          _focusNode.requestFocus();
          widget.onPressed();
        },
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: _focused ? _raised : _surface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _focused ? _amber : _line,
              width: _focused ? 2 : 1,
            ),
          ),
          child: Text(
            widget.episode.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _warmWhite,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    ),
  );
}

class _ContinuationAction extends StatefulWidget {
  const _ContinuationAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.selected = false,
    this.autofocus = false,
    this.focusNode,
    this.onDown,
    this.ensureVisibleOnFocus = false,
  });
  final String label;
  final VoidCallback onPressed;
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
  @override
  Widget build(BuildContext context) => Focus(
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
      child: GestureDetector(
        onTap: () {
          widget.focusNode?.requestFocus();
          widget.onPressed();
        },
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: widget.primary
                ? _amber
                : (widget.selected ? _raised : _surface),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _focused ? _amber : (widget.primary ? _amber : _line),
              width: _focused ? 2 : 1,
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: widget.primary ? const Color(0xFF1B1712) : _warmWhite,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    ),
  );
}
