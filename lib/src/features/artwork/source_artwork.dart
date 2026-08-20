import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../sources/source_models.dart';
import 'artwork_loader.dart';

const _raised = Color(0xFF222321);
const _line = Color(0xFF343534);
const _quietText = Color(0xFFAAA8A2);

/// Fixed-geometry provider artwork with an opt-in bounded visible-row load.
class SourceArtwork extends StatefulWidget {
  const SourceArtwork({
    super.key,
    required this.locator,
    required this.kind,
    required this.loader,
    this.focused = false,
    this.loadWhenVisible = false,
    this.explicitlyActivated = false,
    this.width = 50,
    this.height = 36,
  });

  final String? locator;
  final SourceMediaKind kind;
  final ArtworkProvider? loader;
  final bool focused;

  /// Starts after [ArtworkProvider.focusDwell] while this widget remains
  /// mounted. Virtualized ledgers opt in so their visible/cache window fills
  /// without a click; fast-scrolled rows dispose and cancel before or during
  /// queued work.
  final bool loadWhenVisible;
  final bool explicitlyActivated;
  final double width;
  final double height;

  @override
  State<SourceArtwork> createState() => _SourceArtworkState();
}

class _SourceArtworkState extends State<SourceArtwork> {
  Timer? _dwell;
  ArtworkRequest? _request;
  Uint8List? _bytes;
  bool _loading = false;
  bool _failed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _readCache();
    _updateRequestGate();
  }

  @override
  void didUpdateWidget(covariant SourceArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.locator != widget.locator ||
        oldWidget.loader != widget.loader) {
      _cancelRequest();
      _bytes = null;
      _failed = false;
      _loading = false;
      _readCache();
    }
    if (oldWidget.focused != widget.focused ||
        oldWidget.loadWhenVisible != widget.loadWhenVisible ||
        oldWidget.explicitlyActivated != widget.explicitlyActivated ||
        oldWidget.locator != widget.locator ||
        oldWidget.loader != widget.loader) {
      _updateRequestGate();
    }
  }

  @override
  void dispose() {
    _cancelRequest();
    super.dispose();
  }

  Future<void> _readCache() async {
    final generation = ++_generation;
    final bytes = await widget.loader?.cached(widget.locator);
    if (!mounted || generation != _generation || bytes == null) return;
    setState(() {
      _bytes = bytes;
      _loading = false;
      _failed = false;
    });
  }

  void _updateRequestGate() {
    _dwell?.cancel();
    if (_bytes != null || _failed || widget.loader == null) return;
    if (widget.explicitlyActivated) {
      _startLoad();
    } else if (widget.focused || widget.loadWhenVisible) {
      _dwell = Timer(widget.loader!.focusDwell, _startLoad);
    } else {
      _cancelActiveLoad();
    }
  }

  void _startLoad() {
    if (!mounted || _bytes != null || _failed || _request != null) return;
    final request = widget.loader?.load(widget.locator);
    if (request == null) return;
    final generation = ++_generation;
    _request = request;
    setState(() => _loading = true);
    unawaited(
      request.bytes.then((bytes) {
        if (!mounted || generation != _generation) return;
        _request = null;
        setState(() {
          _bytes = bytes;
          _loading = false;
          _failed = bytes == null;
        });
      }),
    );
  }

  void _cancelActiveLoad() {
    if (_request == null) return;
    _generation++;
    _request?.cancel();
    _request = null;
    if (mounted) setState(() => _loading = false);
  }

  void _cancelRequest() {
    _dwell?.cancel();
    _dwell = null;
    _cancelActiveLoad();
  }

  void _decodeFailed() {
    if (_failed) return;
    setState(() {
      _bytes = null;
      _loading = false;
      _failed = true;
    });
    unawaited(widget.loader?.evict(widget.locator));
  }

  int? _decodeExtent(double logicalExtent) {
    if (!logicalExtent.isFinite || logicalExtent <= 0) return null;
    return (logicalExtent * 2).round().clamp(1, 4096);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.width,
    height: widget.height,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _raised,
          border: Border.all(color: _line),
        ),
        child: _bytes == null
            ? _ArtworkFallback(kind: widget.kind, loading: _loading)
            : Image.memory(
                _bytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: _decodeExtent(widget.width),
                cacheHeight: _decodeExtent(widget.height),
                errorBuilder: (_, _, _) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _decodeFailed();
                  });
                  return _ArtworkFallback(kind: widget.kind, loading: false);
                },
              ),
      ),
    ),
  );
}

class _ArtworkFallback extends StatelessWidget {
  const _ArtworkFallback({required this.kind, required this.loading});

  final SourceMediaKind kind;
  final bool loading;

  @override
  Widget build(BuildContext context) => Center(
    child: loading
        ? const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: _quietText,
            ),
          )
        : Icon(
            switch (kind) {
              SourceMediaKind.live => Icons.live_tv_outlined,
              SourceMediaKind.movies => Icons.movie_outlined,
              SourceMediaKind.series => Icons.tv_outlined,
            },
            size: 18,
            color: _quietText,
          ),
  );
}
