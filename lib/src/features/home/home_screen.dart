import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../home_fixture_mode.dart';

const _graphite = Color(0xFF111212);
const _surface = Color(0xFF191A1A);
const _raised = Color(0xFF222321);
const _line = Color(0xFF343534);
const _warmWhite = Color(0xFFF4F0E7);
const _quietText = Color(0xFFAAA8A2);
const _amber = Color(0xFFFFB347);

enum FixtureKind { live, movie, series }

class FixtureItem {
  const FixtureItem({
    required this.title,
    required this.kind,
    required this.note,
    required this.artSeed,
  });

  final String title;
  final FixtureKind kind;
  final String note;
  final int artSeed;

  String get kindLabel => switch (kind) {
    FixtureKind.live => 'Live',
    FixtureKind.movie => 'Movie',
    FixtureKind.series => 'Series',
  };
}

class FixtureShelf {
  const FixtureShelf({required this.title, required this.items});

  final String title;
  final List<FixtureItem> items;
}

const _shelves = <FixtureShelf>[
  FixtureShelf(
    title: 'Living Room',
    items: [
      FixtureItem(
        title: 'Northbound',
        kind: FixtureKind.live,
        note: 'Pinned channel',
        artSeed: 0,
      ),
      FixtureItem(
        title: 'Field Notes',
        kind: FixtureKind.series,
        note: 'Pinned series',
        artSeed: 1,
      ),
      FixtureItem(
        title: 'Night Signal',
        kind: FixtureKind.movie,
        note: 'Pinned movie',
        artSeed: 2,
      ),
      FixtureItem(
        title: 'The Long Turn',
        kind: FixtureKind.movie,
        note: 'Pinned movie',
        artSeed: 3,
      ),
      FixtureItem(
        title: 'Static Season',
        kind: FixtureKind.series,
        note: 'Pinned series',
        artSeed: 4,
      ),
      FixtureItem(
        title: 'Dawn Relay',
        kind: FixtureKind.live,
        note: 'Pinned channel',
        artSeed: 5,
      ),
    ],
  ),
  FixtureShelf(
    title: 'Weekend Movies',
    items: [
      FixtureItem(
        title: 'Open Waterline',
        kind: FixtureKind.movie,
        note: 'Pinned movie',
        artSeed: 6,
      ),
      FixtureItem(
        title: 'Aperture',
        kind: FixtureKind.movie,
        note: 'Pinned movie',
        artSeed: 7,
      ),
      FixtureItem(
        title: 'Late Check-Out',
        kind: FixtureKind.movie,
        note: 'Pinned movie',
        artSeed: 8,
      ),
      FixtureItem(
        title: 'Small Hours',
        kind: FixtureKind.movie,
        note: 'Pinned movie',
        artSeed: 9,
      ),
    ],
  ),
  FixtureShelf(
    title: 'Favorites',
    items: [
      FixtureItem(
        title: 'Horizon Desk',
        kind: FixtureKind.live,
        note: 'Favorite channel',
        artSeed: 10,
      ),
      FixtureItem(
        title: 'Soft Focus',
        kind: FixtureKind.series,
        note: 'Favorite series',
        artSeed: 11,
      ),
      FixtureItem(
        title: 'Off Hours',
        kind: FixtureKind.movie,
        note: 'Favorite movie',
        artSeed: 0,
      ),
      FixtureItem(
        title: 'Signal Path',
        kind: FixtureKind.live,
        note: 'Favorite channel',
        artSeed: 3,
      ),
    ],
  ),
];

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.fixtureMode,
    required this.showFixtureCopy,
    required this.initialFocus,
    required this.onContentFocus,
    required this.onOpenRail,
    required this.onBrowseLive,
    required this.onBrowseMovies,
    required this.onBrowseSeries,
    required this.onAddSource,
  });

  final HomeFixtureMode fixtureMode;
  final bool showFixtureCopy;
  final FocusNode initialFocus;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onOpenRail;
  final VoidCallback onBrowseLive;
  final VoidCallback onBrowseMovies;
  final VoidCallback onBrowseSeries;
  final VoidCallback onAddSource;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final List<List<FocusNode>> _focusNodes;
  FixtureItem _selectedItem = _shelves.first.items.first;

  @override
  void initState() {
    super.initState();
    _focusNodes = List<List<FocusNode>>.generate(
      _shelves.length,
      (shelfIndex) => List<FocusNode>.generate(
        _shelves[shelfIndex].items.length,
        (itemIndex) => shelfIndex == 0 && itemIndex == 0
            ? widget.initialFocus
            : FocusNode(debugLabel: 'home shelf $shelfIndex item $itemIndex'),
      ),
    );
  }

  @override
  void dispose() {
    for (final row in _focusNodes) {
      for (final node in row) {
        if (node != widget.initialFocus) node.dispose();
      }
    }
    super.dispose();
  }

  void _moveFocus(int shelfIndex, int itemIndex, LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (itemIndex == 0) {
        widget.onOpenRail();
      } else {
        _focusNodes[shelfIndex][itemIndex - 1].requestFocus();
      }
      return;
    }
    if (key == LogicalKeyboardKey.arrowRight &&
        itemIndex < _focusNodes[shelfIndex].length - 1) {
      _focusNodes[shelfIndex][itemIndex + 1].requestFocus();
      return;
    }
    if (key == LogicalKeyboardKey.arrowUp && shelfIndex > 0) {
      final target = math.min(
        itemIndex,
        _focusNodes[shelfIndex - 1].length - 1,
      );
      _focusNodes[shelfIndex - 1][target].requestFocus();
      return;
    }
    if (key == LogicalKeyboardKey.arrowDown &&
        shelfIndex < _focusNodes.length - 1) {
      final target = math.min(
        itemIndex,
        _focusNodes[shelfIndex + 1].length - 1,
      );
      _focusNodes[shelfIndex + 1][target].requestFocus();
    }
  }

  void _activate(FixtureItem item) {
    final message = item.kind == FixtureKind.live
        ? '${item.title} is a local fixture. Live playback is not part of this proof.'
        : '${item.title} is a local fixture. Details are not part of this proof.';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.fixtureMode == HomeFixtureMode.noSources) {
      return _NoSourceHome(
        focusNode: widget.initialFocus,
        onContentFocus: widget.onContentFocus,
        onOpenRail: widget.onOpenRail,
        onAddSource: widget.onAddSource,
      );
    }

    if (widget.fixtureMode == HomeFixtureMode.noPersonalization) {
      return _NoPersonalizationHome(
        showFixtureCopy: widget.showFixtureCopy,
        focusNode: widget.initialFocus,
        onContentFocus: widget.onContentFocus,
        onOpenRail: widget.onOpenRail,
        onBrowseLive: widget.onBrowseLive,
        onBrowseMovies: widget.onBrowseMovies,
        onBrowseSeries: widget.onBrowseSeries,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 780;
        return ColoredBox(
          color: _graphite,
          child: SafeArea(
            left: false,
            child: ListView(
              padding: EdgeInsets.fromLTRB(narrow ? 24 : 48, 22, 32, 48),
              children: [
                _HomeHeader(narrow: narrow),
                const SizedBox(height: 30),
                _FocusedShelf(
                  shelf: _shelves.first,
                  selected: _selectedItem,
                  nodes: _focusNodes.first,
                  narrow: narrow,
                  onFocus: (item, node) {
                    widget.onContentFocus(node);
                    setState(() => _selectedItem = item);
                  },
                  onMove: (index, key) => _moveFocus(0, index, key),
                  onActivate: _activate,
                ),
                const SizedBox(height: 36),
                for (
                  var shelfIndex = 1;
                  shelfIndex < _shelves.length;
                  shelfIndex++
                ) ...[
                  _StandardShelf(
                    shelf: _shelves[shelfIndex],
                    nodes: _focusNodes[shelfIndex],
                    onFocus: (item, node) {
                      widget.onContentFocus(node);
                      setState(() => _selectedItem = item);
                    },
                    onMove: (itemIndex, key) =>
                        _moveFocus(shelfIndex, itemIndex, key),
                    onActivate: _activate,
                  ),
                  const SizedBox(height: 36),
                ],
                const Text(
                  'Illustrative local fixture content — no provider is connected.',
                  style: TextStyle(color: _quietText, fontSize: 13),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({required this.narrow, this.showFixtureCopy = true});

  final bool narrow;
  final bool showFixtureCopy;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      runSpacing: 14,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text(
          'Home',
          style: TextStyle(
            color: _warmWhite,
            fontSize: 31,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.7,
          ),
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerRight,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _surface,
              border: Border.all(color: _line),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.layers_outlined, size: 17, color: _quietText),
                const SizedBox(width: 8),
                Text(
                  showFixtureCopy
                      ? 'All sources · local fixture'
                      : 'All sources',
                  style: const TextStyle(color: _quietText, fontSize: 14),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _FocusedShelf extends StatelessWidget {
  const _FocusedShelf({
    required this.shelf,
    required this.selected,
    required this.nodes,
    required this.narrow,
    required this.onFocus,
    required this.onMove,
    required this.onActivate,
  });

  final FixtureShelf shelf;
  final FixtureItem selected;
  final List<FocusNode> nodes;
  final bool narrow;
  final void Function(FixtureItem, FocusNode) onFocus;
  final void Function(int, LogicalKeyboardKey) onMove;
  final ValueChanged<FixtureItem> onActivate;

  @override
  Widget build(BuildContext context) {
    final details = _ShelfDetails(
      title: shelf.title,
      item: selected,
      fillHeight: !narrow,
    );
    final cards = _CardCarousel(
      items: shelf.items,
      nodes: nodes,
      cardWidth: narrow ? 144 : 172,
      onFocus: onFocus,
      onMove: onMove,
      onActivate: onActivate,
      autofocusFirst: true,
    );

    return Column(
      key: const ValueKey('home-focused-shelf'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (narrow)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              details,
              const SizedBox(height: 18),
              SizedBox(height: 220, child: cards),
            ],
          )
        else
          SizedBox(
            height: 264,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 248, child: details),
                const SizedBox(width: 24),
                Expanded(child: cards),
              ],
            ),
          ),
      ],
    );
  }
}

class _ShelfDetails extends StatelessWidget {
  const _ShelfDetails({
    required this.title,
    required this.item,
    required this.fillHeight,
  });

  final String title;
  final FixtureItem item;
  final bool fillHeight;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
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
            Text(
              title,
              style: const TextStyle(
                color: _warmWhite,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              item.kindLabel.toUpperCase(),
              style: const TextStyle(
                color: _amber,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.7,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _warmWhite,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              item.note,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _quietText,
                fontSize: 14,
                height: 1.35,
              ),
            ),
            if (fillHeight) const Spacer() else const SizedBox(height: 24),
            const Text(
              'Manual order · fixture',
              style: TextStyle(color: _quietText, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _StandardShelf extends StatelessWidget {
  const _StandardShelf({
    required this.shelf,
    required this.nodes,
    required this.onFocus,
    required this.onMove,
    required this.onActivate,
  });

  final FixtureShelf shelf;
  final List<FocusNode> nodes;
  final void Function(FixtureItem, FocusNode) onFocus;
  final void Function(int, LogicalKeyboardKey) onMove;
  final ValueChanged<FixtureItem> onActivate;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          shelf.title,
          style: const TextStyle(
            color: _warmWhite,
            fontSize: 21,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 220,
          child: _CardCarousel(
            items: shelf.items,
            nodes: nodes,
            cardWidth: 152,
            onFocus: onFocus,
            onMove: onMove,
            onActivate: onActivate,
          ),
        ),
      ],
    );
  }
}

class _CardCarousel extends StatelessWidget {
  const _CardCarousel({
    required this.items,
    required this.nodes,
    required this.cardWidth,
    required this.onFocus,
    required this.onMove,
    required this.onActivate,
    this.autofocusFirst = false,
  });

  final List<FixtureItem> items;
  final List<FocusNode> nodes;
  final double cardWidth;
  final void Function(FixtureItem, FocusNode) onFocus;
  final void Function(int, LogicalKeyboardKey) onMove;
  final ValueChanged<FixtureItem> onActivate;
  final bool autofocusFirst;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(vertical: 2),
      clipBehavior: Clip.none,
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(width: 14),
      itemBuilder: (context, index) => SizedBox(
        width: cardWidth,
        child: _FixtureCard(
          item: items[index],
          focusNode: nodes[index],
          onFocused: () => onFocus(items[index], nodes[index]),
          onMove: (key) => onMove(index, key),
          onActivate: () => onActivate(items[index]),
          autofocus: autofocusFirst && index == 0,
        ),
      ),
    );
  }
}

class _FixtureCard extends StatefulWidget {
  const _FixtureCard({
    required this.item,
    required this.focusNode,
    required this.onFocused,
    required this.onMove,
    required this.onActivate,
    required this.autofocus,
  });

  final FixtureItem item;
  final FocusNode focusNode;
  final VoidCallback onFocused;
  final ValueChanged<LogicalKeyboardKey> onMove;
  final VoidCallback onActivate;
  final bool autofocus;

  @override
  State<_FixtureCard> createState() => _FixtureCardState();
}

class _FixtureCardState extends State<_FixtureCard> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = _focused || _hovered;
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (focused) {
          widget.onFocused();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Scrollable.ensureVisible(
                context,
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOutCubic,
                alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
              );
            }
          });
        }
      },
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.select) {
          widget.onActivate();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight ||
            key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown) {
          widget.onMove(key);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Semantics(
        key: ValueKey('fixture-card-${widget.item.title}'),
        button: true,
        label: '${widget.item.title}, ${widget.item.kindLabel}, fixture item',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: () {
              widget.focusNode.requestFocus();
              widget.onActivate();
            },
            child: AnimatedScale(
              scale: active ? 1.025 : 1,
              duration: const Duration(milliseconds: 130),
              curve: Curves.easeOutCubic,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 130),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  color: _raised,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: _focused ? _amber : _line,
                    width: _focused ? 2 : 1,
                  ),
                  boxShadow: active
                      ? const [
                          BoxShadow(
                            color: Color(0x55000000),
                            offset: Offset(0, 8),
                            blurRadius: 16,
                          ),
                        ]
                      : null,
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: SizedBox.expand(
                        child: CustomPaint(
                          painter: _FixtureArtworkPainter(widget.item.artSeed),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _warmWhite,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            widget.item.kindLabel,
                            style: const TextStyle(
                              color: _quietText,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FixtureArtworkPainter extends CustomPainter {
  _FixtureArtworkPainter(this.seed);

  final int seed;

  static const _palettes = <List<Color>>[
    [Color(0xFF274A53), Color(0xFF83B9B1), Color(0xFF15262B)],
    [Color(0xFF4C354E), Color(0xFFD78377), Color(0xFF271C2A)],
    [Color(0xFF504223), Color(0xFFD9BC6C), Color(0xFF292317)],
    [Color(0xFF203D5A), Color(0xFF7FACC9), Color(0xFF162230)],
    [Color(0xFF4D2E30), Color(0xFFC4765D), Color(0xFF28191A)],
    [Color(0xFF30503F), Color(0xFF93BE84), Color(0xFF1C3026)],
    [Color(0xFF463D67), Color(0xFF9F91D6), Color(0xFF26223A)],
    [Color(0xFF4A402D), Color(0xFFBBA56A), Color(0xFF292319)],
    [Color(0xFF25444C), Color(0xFF6DA6A4), Color(0xFF14272B)],
    [Color(0xFF5B3248), Color(0xFFD18AAB), Color(0xFF321B28)],
    [Color(0xFF30465E), Color(0xFF9CB8D3), Color(0xFF1B2837)],
    [Color(0xFF4E3D2B), Color(0xFFD19E69), Color(0xFF2B2318)],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final palette = _palettes[seed % _palettes.length];
    final base = Paint()..color = palette[0];
    canvas.drawRect(Offset.zero & size, base);
    final accent = Paint()..color = palette[1];
    final dark = Paint()..color = palette[2];
    final unit = math.min(size.width, size.height);
    switch (seed % 6) {
      case 0:
        canvas.drawCircle(
          Offset(size.width * .72, size.height * .35),
          unit * .32,
          accent,
        );
        canvas.drawRect(
          Rect.fromLTWH(0, size.height * .68, size.width, size.height * .32),
          dark,
        );
      case 1:
        canvas.drawPath(
          Path()
            ..moveTo(0, size.height * .2)
            ..lineTo(size.width, size.height * .65)
            ..lineTo(size.width, size.height)
            ..lineTo(0, size.height * .7)
            ..close(),
          dark,
        );
        canvas.drawRect(
          Rect.fromLTWH(size.width * .2, 0, unit * .15, size.height),
          accent,
        );
      case 2:
        canvas.drawCircle(
          Offset(size.width * .3, size.height * .35),
          unit * .2,
          accent,
        );
        canvas.drawCircle(
          Offset(size.width * .66, size.height * .7),
          unit * .34,
          dark,
        );
      case 3:
        canvas.drawPath(
          Path()
            ..moveTo(size.width * .05, size.height)
            ..lineTo(size.width * .52, 0)
            ..lineTo(size.width, size.height * .82)
            ..lineTo(size.width, size.height)
            ..close(),
          dark,
        );
        canvas.drawRect(
          Rect.fromLTWH(size.width * .72, 0, unit * .12, size.height),
          accent,
        );
      case 4:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              size.width * .12,
              size.height * .12,
              size.width * .76,
              size.height * .76,
            ),
            Radius.circular(unit * .16),
          ),
          dark,
        );
        canvas.drawCircle(
          Offset(size.width * .5, size.height * .48),
          unit * .22,
          accent,
        );
      case 5:
        canvas.drawRect(
          Rect.fromLTWH(0, size.height * .58, size.width, size.height * .42),
          dark,
        );
        for (var i = 0; i < 4; i++) {
          canvas.drawRect(
            Rect.fromLTWH(
              size.width * (.1 + i * .22),
              size.height * (.12 + i * .05),
              unit * .1,
              size.height * .55,
            ),
            accent,
          );
        }
    }
    final line = Paint()
      ..color = const Color(0x33F4F0E7)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height * .83),
      Offset(size.width, size.height * .83),
      line,
    );
  }

  @override
  bool shouldRepaint(covariant _FixtureArtworkPainter oldDelegate) =>
      oldDelegate.seed != seed;
}

class _NoPersonalizationHome extends StatefulWidget {
  const _NoPersonalizationHome({
    required this.showFixtureCopy,
    required this.focusNode,
    required this.onContentFocus,
    required this.onOpenRail,
    required this.onBrowseLive,
    required this.onBrowseMovies,
    required this.onBrowseSeries,
  });

  final bool showFixtureCopy;
  final FocusNode focusNode;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onOpenRail;
  final VoidCallback onBrowseLive;
  final VoidCallback onBrowseMovies;
  final VoidCallback onBrowseSeries;

  @override
  State<_NoPersonalizationHome> createState() => _NoPersonalizationHomeState();
}

class _NoPersonalizationHomeState extends State<_NoPersonalizationHome> {
  late final List<FocusNode> _nodes = [
    widget.focusNode,
    FocusNode(debugLabel: 'no-personalization movies'),
    FocusNode(debugLabel: 'no-personalization series'),
  ];

  void _moveFocus(int index, LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (index == 0) {
        widget.onOpenRail();
      } else {
        _nodes[index - 1].requestFocus();
      }
      return;
    }

    if (key == LogicalKeyboardKey.arrowRight && index < _nodes.length - 1) {
      _nodes[index + 1].requestFocus();
    }
  }

  @override
  void dispose() {
    for (final node in _nodes.skip(1)) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _graphite,
      child: SafeArea(
        left: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(48, 22, 32, 48),
          children: [
            _HomeHeader(narrow: false, showFixtureCopy: widget.showFixtureCopy),
            const SizedBox(height: 56),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 700),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Start with what you want to watch',
                    style: TextStyle(
                      color: _warmWhite,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.showFixtureCopy
                        ? 'This local source fixture has no Favorites, groups, or watch history yet.'
                        : 'Your library has no Favorites, groups, or watch history yet.',
                    style: const TextStyle(
                      color: _quietText,
                      fontSize: 16,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 28),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _DirectEntry(
                        label: 'Live',
                        icon: Icons.live_tv_outlined,
                        focusNode: _nodes[0],
                        autofocus: true,
                        onFocused: () => widget.onContentFocus(_nodes[0]),
                        onMove: (key) => _moveFocus(0, key),
                        onPressed: widget.onBrowseLive,
                      ),
                      _DirectEntry(
                        label: 'Movies',
                        icon: Icons.movie_outlined,
                        focusNode: _nodes[1],
                        onFocused: () => widget.onContentFocus(_nodes[1]),
                        onMove: (key) => _moveFocus(1, key),
                        onPressed: widget.onBrowseMovies,
                      ),
                      _DirectEntry(
                        label: 'Series',
                        icon: Icons.tv_outlined,
                        focusNode: _nodes[2],
                        onFocused: () => widget.onContentFocus(_nodes[2]),
                        onMove: (key) => _moveFocus(2, key),
                        onPressed: widget.onBrowseSeries,
                      ),
                    ],
                  ),
                  const SizedBox(height: 30),
                  const Text(
                    'Favorite something or create a group to make Home personal.',
                    style: TextStyle(color: _quietText, fontSize: 14),
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

class _DirectEntry extends StatefulWidget {
  const _DirectEntry({
    required this.label,
    required this.icon,
    required this.focusNode,
    required this.onFocused,
    required this.onMove,
    required this.onPressed,
    this.autofocus = false,
  });

  final String label;
  final IconData icon;
  final FocusNode focusNode;
  final VoidCallback onFocused;
  final ValueChanged<LogicalKeyboardKey> onMove;
  final VoidCallback onPressed;
  final bool autofocus;

  @override
  State<_DirectEntry> createState() => _DirectEntryState();
}

class _DirectEntryState extends State<_DirectEntry> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (focused) widget.onFocused();
      },
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowRight) {
          widget.onMove(event.logicalKey);
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
        label: 'Browse ${widget.label}',
        child: GestureDetector(
          onTap: () {
            widget.focusNode.requestFocus();
            widget.onPressed();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _focused ? _amber : _line,
                width: _focused ? 2 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, color: _warmWhite, size: 20),
                const SizedBox(width: 10),
                Text(
                  widget.label,
                  style: const TextStyle(
                    color: _warmWhite,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NoSourceHome extends StatelessWidget {
  const _NoSourceHome({
    required this.focusNode,
    required this.onContentFocus,
    required this.onOpenRail,
    required this.onAddSource,
  });

  final FocusNode focusNode;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onOpenRail;
  final VoidCallback onAddSource;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _graphite,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.add_to_queue_outlined,
                  color: _amber,
                  size: 34,
                ),
                const SizedBox(height: 20),
                const Text(
                  'Add your first source',
                  style: TextStyle(
                    color: _warmWhite,
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Wabbit TV supplies no content. Connect your Xtream account to begin.',
                  style: TextStyle(
                    color: _quietText,
                    fontSize: 16,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 26),
                _FocusedAction(
                  label: 'Add source',
                  focusNode: focusNode,
                  onFocused: () => onContentFocus(focusNode),
                  onLeft: onOpenRail,
                  onPressed: onAddSource,
                ),
                const SizedBox(height: 18),
                const Text(
                  'Press Escape or Left to open navigation.',
                  style: TextStyle(color: _quietText, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FocusedAction extends StatefulWidget {
  const _FocusedAction({
    required this.label,
    required this.focusNode,
    required this.onFocused,
    required this.onLeft,
    required this.onPressed,
  });

  final String label;
  final FocusNode focusNode;
  final VoidCallback onFocused;
  final VoidCallback onLeft;
  final VoidCallback onPressed;

  @override
  State<_FocusedAction> createState() => _FocusedActionState();
}

class _FocusedActionState extends State<_FocusedAction> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: true,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (focused) widget.onFocused();
      },
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          widget.onLeft();
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
        label: widget.label,
        child: GestureDetector(
          onTap: () {
            widget.focusNode.requestFocus();
            widget.onPressed();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: _amber,
              borderRadius: BorderRadius.circular(6),
              border: _focused ? Border.all(color: _warmWhite, width: 2) : null,
            ),
            child: Text(
              widget.label,
              style: const TextStyle(
                color: Color(0xFF17120A),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
