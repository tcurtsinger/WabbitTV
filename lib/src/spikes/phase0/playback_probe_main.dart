import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'strong_playback_probe.dart';
import 'strong_probe_models.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const PlaybackProbeApp());
}

class PlaybackProbeApp extends StatelessWidget {
  const PlaybackProbeApp({super.key, this.initialAccount});

  final StrongAccountFacts? initialAccount;

  @override
  Widget build(BuildContext context) {
    const amber = Color(0xFFFFB347);
    const warmWhite = Color(0xFFF4F0E7);
    const line = Color(0xFF343534);
    return MaterialApp(
      title: 'Wabbit TV Playback Probe',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: 'Segoe UI',
        scaffoldBackgroundColor: const Color(0xFF111212),
        colorScheme: const ColorScheme.dark(
          primary: amber,
          onPrimary: Color(0xFF17120A),
          surface: Color(0xFF191A1A),
          onSurface: warmWhite,
          secondary: Color(0xFFAAA8A2),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Color(0xFF191A1A),
          labelStyle: TextStyle(color: Color(0xFFAAA8A2)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(6)),
            borderSide: BorderSide(color: line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(6)),
            borderSide: BorderSide(color: amber, width: 2),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: warmWhite,
            side: const BorderSide(color: line),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(6)),
            ),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: amber,
            foregroundColor: const Color(0xFF17120A),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(6)),
            ),
          ),
        ),
      ),
      home: PlaybackProbeScreen(initialAccount: initialAccount),
    );
  }
}

class PlaybackProbeScreen extends StatefulWidget {
  const PlaybackProbeScreen({super.key, this.initialAccount});

  final StrongAccountFacts? initialAccount;

  @override
  State<PlaybackProbeScreen> createState() => _PlaybackProbeScreenState();
}

class _PlaybackProbeScreenState extends State<PlaybackProbeScreen> {
  final _endpointController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final List<ProbeEvidence> _evidence = [];

  StrongProbeClient? _client;
  StrongProbeCredentials? _credentials;
  StrongAccountFacts? _account;
  List<ProbeCategory> _liveCategories = const [];
  List<ProbeCategory> _movieCategories = const [];
  List<ProbeCategory> _seriesCategories = const [];
  List<ProbeStreamCandidate> _liveCandidates = const [];
  ProbeStreamCandidate? _selectedLive;
  ProbeStreamCandidate? _selectedMovie;
  ProbeStreamCandidate? _selectedEpisode;
  ProbePlaybackHandle? _activePlayback;
  List<ProbePlaybackHandle> _twoStreamPlayback = const [];
  TwoStreamEvidence _twoStream = const TwoStreamEvidence(
    attempted: false,
    passed: null,
  );
  ProbeFailure? _notice;
  bool _working = false;
  String _stageLabel = 'Awaiting a local account check';

  StrongProbeClient get _probeClient => _client ??= StrongProbeClient();

  @override
  void initState() {
    super.initState();
    _account = widget.initialAccount;
    if (_account != null && !_account!.authenticated) {
      _notice = ProbeFailure.authentication;
      _stageLabel =
          'Account access was not confirmed. Retry with new credentials.';
    }
  }

  @override
  void dispose() {
    _endpointController.clear();
    _usernameController.clear();
    _passwordController.clear();
    _endpointController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _credentials = null;
    _client?.close();
    final active = _activePlayback;
    if (active != null) unawaited(active.dispose());
    for (final playback in _twoStreamPlayback) {
      unawaited(playback.dispose());
    }
    super.dispose();
  }

  Future<void> _checkAccount() async {
    if (_working || _formKey.currentState?.validate() != true) return;
    final credentials = StrongProbeCredentials(
      endpoint: _endpointController.text,
      username: _usernameController.text,
      password: _passwordController.text,
    );
    setState(() {
      _working = true;
      _notice = null;
      _stageLabel = 'Checking account facts';
    });
    try {
      final account = await _probeClient.checkAccount(credentials);
      if (!mounted) return;
      setState(() {
        _account = account;
        if (account.authenticated) {
          _credentials = credentials;
          _stageLabel = account.permitsSingleStream
              ? 'Account facts confirmed. Choose representative streams.'
              : 'No connection is available. Close a provider stream, then check again.';
          _notice = null;
        } else {
          _credentials = null;
          _endpointController.clear();
          _usernameController.clear();
          _passwordController.clear();
          _stageLabel =
              'Account access was not confirmed. Retry with new credentials.';
          _notice = ProbeFailure.authentication;
        }
      });
    } on ProbeRequestException catch (error) {
      if (!mounted) return;
      setState(() {
        _credentials = null;
        _endpointController.clear();
        _usernameController.clear();
        _passwordController.clear();
        _notice = error.failure;
        _stageLabel = '${error.failure.label}. Re-enter credentials to retry.';
      });
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _discoverRepresentatives() async {
    final credentials = _credentials;
    if (_working || credentials == null || _account?.authenticated != true) {
      return;
    }
    var currentKind = ProbeMediaKind.live;
    setState(() {
      _working = true;
      _notice = null;
      _stageLabel = categoryDiscoveryProgressLabel(currentKind, 1);
    });
    try {
      final live = await _probeClient.discoverCategories(
        credentials,
        currentKind,
      );
      if (!mounted) return;
      currentKind = ProbeMediaKind.movie;
      setState(
        () => _stageLabel = categoryDiscoveryProgressLabel(currentKind, 2),
      );
      final movies = await _probeClient.discoverCategories(
        credentials,
        currentKind,
      );
      if (!mounted) return;
      currentKind = ProbeMediaKind.episode;
      setState(
        () => _stageLabel = categoryDiscoveryProgressLabel(currentKind, 3),
      );
      final series = await _probeClient.discoverCategories(
        credentials,
        currentKind,
      );
      if (!mounted) return;
      setState(() {
        _liveCategories = live;
        _movieCategories = movies;
        _seriesCategories = series;
        _liveCandidates = const [];
        _selectedLive = null;
        _selectedMovie = null;
        _selectedEpisode = null;
        _stageLabel = 'Choose a category for each representative.';
      });
    } on ProbeRequestException catch (error) {
      if (!mounted) return;
      setState(() {
        _notice = error.failure;
        _stageLabel = categoryDiscoveryFailureLabel(currentKind, error.failure);
      });
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<ProbeCategory?> _pickCategory(
    List<ProbeCategory> categories,
    String title,
  ) async {
    if (categories.isEmpty || _working) return null;
    return showDialog<ProbeCategory>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF191A1A),
        title: Text(title),
        content: SizedBox(
          width: 440,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: categories.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) => ListTile(
              title: Text(
                categories[index].name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.of(context).pop(categories[index]),
            ),
          ),
        ),
      ),
    );
  }

  Future<ProbeStreamCandidate?> _pickCandidate(
    List<ProbeStreamCandidate> candidates,
    String title,
  ) async {
    if (candidates.isEmpty || _working) return null;
    return showDialog<ProbeStreamCandidate>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF191A1A),
        title: Text(title),
        content: SizedBox(
          width: 440,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: candidates.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) => ListTile(
              title: Text(
                candidates[index].title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.of(context).pop(candidates[index]),
            ),
          ),
        ),
      ),
    );
  }

  List<ProbeCategory> _categoriesFor(ProbeMediaKind kind) => switch (kind) {
    ProbeMediaKind.live => _liveCategories,
    ProbeMediaKind.movie => _movieCategories,
    ProbeMediaKind.episode => _seriesCategories,
  };

  void _setCandidates(ProbeMediaKind kind, List<ProbeStreamCandidate> values) {
    if (kind == ProbeMediaKind.live) _liveCandidates = values;
  }

  String _categoryPickerTitle(ProbeMediaKind kind) => switch (kind) {
    ProbeMediaKind.live => 'Choose a live category',
    ProbeMediaKind.movie => 'Choose a movie category',
    ProbeMediaKind.episode => 'Choose a series category',
  };

  String _candidatePickerTitle(ProbeMediaKind kind) => switch (kind) {
    ProbeMediaKind.live => 'Choose a live channel',
    ProbeMediaKind.movie => 'Choose a movie',
    ProbeMediaKind.episode => 'Choose a series',
  };

  Future<ProbeStreamCandidate?> _chooseCategoryCandidate(
    ProbeMediaKind kind,
  ) async {
    final credentials = _credentials;
    if (_working || credentials == null) return null;
    final category = await _pickCategory(
      _categoriesFor(kind),
      _categoryPickerTitle(kind),
    );
    if (category == null || !mounted) return null;

    List<ProbeStreamCandidate>? candidates;
    setState(() {
      _working = true;
      _notice = null;
      _stageLabel = categoryCandidateProgressLabel(kind);
    });
    try {
      candidates = await _probeClient.discoverCategoryCandidates(
        credentials,
        category,
      );
      if (!mounted) return null;
      setState(() => _setCandidates(kind, candidates!));
    } on ProbeRequestException catch (error) {
      if (!mounted) return null;
      setState(() {
        _notice = error.failure;
        _stageLabel = categoryCandidateFailureLabel(kind, error.failure);
      });
    } finally {
      if (mounted) setState(() => _working = false);
    }
    if (candidates == null || !mounted) return null;
    if (candidates.isEmpty) {
      setState(() {
        _stageLabel =
            '${kind == ProbeMediaKind.episode ? 'Series' : kind.label} category returned no candidates.';
      });
      return null;
    }
    return _pickCandidate(candidates, _candidatePickerTitle(kind));
  }

  Future<void> _pickLive() async {
    final selected = await _chooseCategoryCandidate(ProbeMediaKind.live);
    if (selected != null && mounted) {
      setState(() => _selectedLive = selected);
    }
  }

  Future<void> _pickMovie() async {
    final selected = await _chooseCategoryCandidate(ProbeMediaKind.movie);
    if (selected != null && mounted) {
      setState(() => _selectedMovie = selected);
    }
  }

  Future<void> _pickEpisode() async {
    final credentials = _credentials;
    if (credentials == null) return;
    final series = await _chooseCategoryCandidate(ProbeMediaKind.episode);
    if (series == null || !mounted) return;

    List<ProbeStreamCandidate>? episodes;
    setState(() {
      _working = true;
      _notice = null;
      _stageLabel = 'Finding episodes for the selected series';
    });
    try {
      episodes = await _probeClient.discoverEpisodes(credentials, series);
    } on ProbeRequestException catch (error) {
      if (!mounted) return;
      setState(() {
        _notice = error.failure;
        _stageLabel = 'Episode lookup: ${error.failure.label}';
      });
    } finally {
      if (mounted) setState(() => _working = false);
    }
    if (episodes == null || !mounted) return;
    final selected = await _pickCandidate(episodes, 'Choose an episode');
    if (selected != null && mounted) {
      setState(() {
        _selectedEpisode = selected;
        _stageLabel = 'All representatives are ready.';
      });
    }
  }

  bool get _canRunSequential =>
      _selectedLive != null &&
      _selectedMovie != null &&
      _selectedEpisode != null &&
      _account?.permitsSingleStream == true;

  bool get _singleStreamBlocked =>
      _account != null && !_account!.permitsSingleStream;

  void _retryAccount() {
    if (_working) return;
    setState(() {
      _credentials = null;
      _account = null;
      _endpointController.clear();
      _usernameController.clear();
      _passwordController.clear();
      _notice = null;
      _stageLabel = 'Enter credentials locally to retry the account check.';
    });
  }

  Future<void> _runSequential() async {
    final credentials = _credentials;
    if (_working ||
        credentials == null ||
        !_canRunSequential ||
        _account?.permitsSingleStream != true) {
      if (mounted && _singleStreamBlocked) {
        setState(() {
          _stageLabel = 'No connection is available. Close a provider stream, then check again.';
        });
      }
      return;
    }
    final selections = [_selectedLive!, _selectedMovie!, _selectedEpisode!];
    setState(() {
      _working = true;
      _notice = null;
      _evidence.clear();
    });
    try {
      for (final candidate in selections) {
        final playback = ProbePlaybackHandle();
        try {
          setState(() {
            _activePlayback = playback;
            _stageLabel =
                'Rendering ${candidate.kind.label.toLowerCase()} evidence';
          });
          await WidgetsBinding.instance.endOfFrame;
          final result = await playback.run(
            candidate,
            buildXtreamPlaybackUri(credentials, candidate),
          );
          if (!mounted) return;
          setState(() {
            _evidence.add(result);
            _stageLabel = result.passed
                ? '${candidate.kind.label} evidence captured'
                : result.failure!.label;
          });
        } finally {
          await playback.dispose();
          if (mounted) setState(() => _activePlayback = null);
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _runTwoStream() async {
    final credentials = _credentials;
    if (_working ||
        credentials == null ||
        _account?.permitsTwoStreams != true ||
        _liveCandidates.length < 2) {
      return;
    }
    final first = _selectedLive ?? _liveCandidates.first;
    final second = _liveCandidates.firstWhere(
      (candidate) => candidate.id != first.id,
      orElse: () => first,
    );
    if (identical(first, second) || first.id == second.id) return;
    final players = [ProbePlaybackHandle(), ProbePlaybackHandle()];
    setState(() {
      _working = true;
      _twoStreamPlayback = players;
      _twoStream = const TwoStreamEvidence(attempted: true, passed: null);
      _stageLabel = 'Running the explicit two-stream technical check';
    });
    await WidgetsBinding.instance.endOfFrame;
    try {
      final results = await Future.wait([
        players[0].run(first, buildXtreamPlaybackUri(credentials, first)),
        players[1].run(second, buildXtreamPlaybackUri(credentials, second)),
      ]);
      final passed = results.every((result) => result.passed);
      if (passed) await Future<void>.delayed(const Duration(seconds: 5));
      if (!mounted) return;
      setState(() {
        _twoStream = TwoStreamEvidence(attempted: true, passed: passed);
        _stageLabel = passed
            ? 'Two-stream evidence captured'
            : 'Two-stream check did not pass';
      });
    } finally {
      for (final player in players) {
        await player.dispose();
      }
      if (mounted) {
        setState(() {
          _twoStreamPlayback = const [];
          _working = false;
        });
      }
    }
  }

  String _evidenceText() {
    final account = _account;
    final accountText = account == null
        ? 'Account: not checked'
        : 'Account: ${account.authenticated ? 'confirmed' : 'not confirmed'} | '
              'status ${account.status} | max ${account.maxConnections ?? 'unknown'} | '
              'active ${account.activeConnections ?? 'unknown'}';
    return [
      accountText,
      ..._evidence.map((result) => result.toSanitizedText()),
      'Two streams: ${_twoStream.label}',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 930;
              final console = _TaskConsole(
                formKey: _formKey,
                endpointController: _endpointController,
                usernameController: _usernameController,
                passwordController: _passwordController,
                account: _account,
                working: _working,
                canDiscover:
                    _credentials != null && _account?.authenticated == true,
                liveReady: _selectedLive != null,
                movieReady: _selectedMovie != null,
                episodeReady: _selectedEpisode != null,
                hasLiveCandidates: _liveCategories.isNotEmpty,
                hasMovieCandidates: _movieCategories.isNotEmpty,
                hasSeriesCandidates: _seriesCategories.isNotEmpty,
                canRun: _canRunSequential,
                singleStreamBlocked: _singleStreamBlocked,
                canRunTwo:
                    _account?.permitsTwoStreams == true &&
                    _liveCandidates.length >= 2,
                twoStream: _twoStream,
                onCheckAccount: _checkAccount,
                onRetryAccount: _retryAccount,
                onDiscover: _discoverRepresentatives,
                onPickLive: _pickLive,
                onPickMovie: _pickMovie,
                onPickEpisode: _pickEpisode,
                onRunSequential: _runSequential,
                onRunTwo: _runTwoStream,
              );
              final evidence = _EvidenceStage(
                stageLabel: _stageLabel,
                notice: _notice,
                activePlayback: _activePlayback,
                twoStreamPlayback: _twoStreamPlayback,
                evidenceText: _evidenceText(),
                boundedHeight: !narrow,
              );
              return Padding(
                padding: const EdgeInsets.all(24),
                child: narrow
                    ? SingleChildScrollView(
                        child: Column(
                          children: [
                            console,
                            const SizedBox(height: 16),
                            evidence,
                          ],
                        ),
                      )
                    : Row(
                        children: [
                          SizedBox(width: 344, child: console),
                          const SizedBox(width: 20),
                          Expanded(
                            child: SizedBox(
                              height: constraints.maxHeight,
                              child: evidence,
                            ),
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

class _TaskConsole extends StatelessWidget {
  const _TaskConsole({
    required this.formKey,
    required this.endpointController,
    required this.usernameController,
    required this.passwordController,
    required this.account,
    required this.working,
    required this.canDiscover,
    required this.liveReady,
    required this.movieReady,
    required this.episodeReady,
    required this.hasLiveCandidates,
    required this.hasMovieCandidates,
    required this.hasSeriesCandidates,
    required this.canRun,
    required this.singleStreamBlocked,
    required this.canRunTwo,
    required this.twoStream,
    required this.onCheckAccount,
    required this.onRetryAccount,
    required this.onDiscover,
    required this.onPickLive,
    required this.onPickMovie,
    required this.onPickEpisode,
    required this.onRunSequential,
    required this.onRunTwo,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController endpointController;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final StrongAccountFacts? account;
  final bool working;
  final bool canDiscover;
  final bool liveReady;
  final bool movieReady;
  final bool episodeReady;
  final bool hasLiveCandidates;
  final bool hasMovieCandidates;
  final bool hasSeriesCandidates;
  final bool canRun;
  final bool singleStreamBlocked;
  final bool canRunTwo;
  final TwoStreamEvidence twoStream;
  final Future<void> Function() onCheckAccount;
  final VoidCallback onRetryAccount;
  final Future<void> Function() onDiscover;
  final VoidCallback onPickLive;
  final VoidCallback onPickMovie;
  final Future<void> Function() onPickEpisode;
  final Future<void> Function() onRunSequential;
  final Future<void> Function() onRunTwo;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF191A1A),
        border: Border.all(color: const Color(0xFF343534)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Playback probe',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            const Text(
              'Temporary local diagnostic. Nothing is saved or logged.',
              style: TextStyle(color: Color(0xFFAAA8A2)),
            ),
            const SizedBox(height: 24),
            _SectionTitle('Account'),
            const SizedBox(height: 10),
            if (account == null) ...[
              Form(
                key: formKey,
                child: Column(
                  children: [
                    TextFormField(
                      controller: endpointController,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Provider endpoint',
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? 'Enter an endpoint'
                          : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: usernameController,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: 'Username'),
                      validator: (value) => value == null || value.isEmpty
                          ? 'Enter a username'
                          : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: passwordController,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      onFieldSubmitted: (_) => onCheckAccount(),
                      decoration: const InputDecoration(labelText: 'Password'),
                      validator: (value) => value == null || value.isEmpty
                          ? 'Enter a password'
                          : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: working ? null : onCheckAccount,
                child: Text(working ? 'Checking…' : 'Check account'),
              ),
            ] else ...[
              _AccountFacts(account: account!),
              if (!account!.authenticated) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: working ? null : onRetryAccount,
                  child: const Text('Retry with new credentials'),
                ),
              ],
            ],
            const SizedBox(height: 24),
            _SectionTitle('Select'),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: canDiscover && !working ? onDiscover : null,
              child: const Text('Find representative items'),
            ),
            const SizedBox(height: 8),
            _ChoiceButton(
              label: liveReady ? 'Live selected' : 'Choose live',
              enabled: hasLiveCandidates && !working,
              onPressed: onPickLive,
            ),
            const SizedBox(height: 8),
            _ChoiceButton(
              label: movieReady ? 'Movie selected' : 'Choose movie',
              enabled: hasMovieCandidates && !working,
              onPressed: onPickMovie,
            ),
            const SizedBox(height: 8),
            _ChoiceButton(
              label: episodeReady ? 'Episode selected' : 'Choose episode',
              enabled: hasSeriesCandidates && !working,
              onPressed: onPickEpisode,
            ),
            const SizedBox(height: 24),
            _SectionTitle('Playback'),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: canRun && !working ? onRunSequential : null,
              child: const Text('Run three checks'),
            ),
            if (singleStreamBlocked) ...[
              const SizedBox(height: 8),
              const Text(
                'No provider connection is currently available. Close a stream elsewhere, then check the account again.',
                style: TextStyle(color: Color(0xFFFFB347)),
              ),
            ],
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: canRunTwo && !working ? onRunTwo : null,
              child: Text(
                canRunTwo ? 'Run two-stream check' : 'Two-stream unavailable',
              ),
            ),
            const SizedBox(height: 24),
            _SectionTitle('Results'),
            const SizedBox(height: 10),
            Text(
              'Two-stream: ${twoStream.label}',
              style: const TextStyle(color: Color(0xFFAAA8A2)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.titleMedium
        ?.copyWith(fontWeight: FontWeight.w700),
  );
}

class _ChoiceButton extends StatelessWidget {
  const _ChoiceButton({
    required this.label,
    required this.enabled,
    required this.onPressed,
  });
  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) =>
      OutlinedButton(onPressed: enabled ? onPressed : null, child: Text(label));
}

class _AccountFacts extends StatelessWidget {
  const _AccountFacts({required this.account});
  final StrongAccountFacts account;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xFF222321),
      border: Border.all(color: const Color(0xFF343534)),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Text(
        'Access: ${account.authenticated ? 'confirmed' : 'not confirmed'}\n'
        'Status: ${account.status}\n'
        'Maximum connections: ${account.maxConnections ?? 'unknown'}\n'
        'Active connections: ${account.activeConnections ?? 'unknown'}',
        style: const TextStyle(color: Color(0xFFF4F0E7)),
      ),
    ),
  );
}

class _EvidenceStage extends StatelessWidget {
  const _EvidenceStage({
    required this.stageLabel,
    required this.notice,
    required this.activePlayback,
    required this.twoStreamPlayback,
    required this.evidenceText,
    required this.boundedHeight,
  });

  final String stageLabel;
  final ProbeFailure? notice;
  final ProbePlaybackHandle? activePlayback;
  final List<ProbePlaybackHandle> twoStreamPlayback;
  final String evidenceText;
  final bool boundedHeight;

  @override
  Widget build(BuildContext context) {
    final isTwoStream = twoStreamPlayback.length == 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Mounted render evidence',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 6),
        Text(stageLabel, style: const TextStyle(color: Color(0xFFAAA8A2))),
        const SizedBox(height: 14),
        if (boundedHeight)
          Flexible(
            fit: FlexFit.loose,
            child: Align(
              alignment: Alignment.topLeft,
              child: _VideoStage(
                isTwoStream: isTwoStream,
                activePlayback: activePlayback,
                twoStreamPlayback: twoStreamPlayback,
              ),
            ),
          )
        else
          _VideoStage(
            isTwoStream: isTwoStream,
            activePlayback: activePlayback,
            twoStreamPlayback: twoStreamPlayback,
          ),
        const SizedBox(height: 14),
        if (notice != null)
          Text(notice!.label, style: const TextStyle(color: Color(0xFFFFB347))),
        const SizedBox(height: 14),
        DecoratedBox(
          key: const ValueKey('playback-probe-evidence-ledger'),
          decoration: BoxDecoration(
            color: const Color(0xFF191A1A),
            border: Border.all(color: const Color(0xFF343534)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              evidenceText,
              style: const TextStyle(color: Color(0xFFF4F0E7), height: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

class _VideoStage extends StatelessWidget {
  const _VideoStage({
    required this.isTwoStream,
    required this.activePlayback,
    required this.twoStreamPlayback,
  });

  final bool isTwoStream;
  final ProbePlaybackHandle? activePlayback;
  final List<ProbePlaybackHandle> twoStreamPlayback;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black,
          border: Border.all(color: const Color(0xFF343534)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: isTwoStream
              ? Row(
                  children: [
                    Expanded(
                      child: Video(
                        controller: twoStreamPlayback[0].controller,
                        controls: NoVideoControls,
                      ),
                    ),
                    const VerticalDivider(width: 1, color: Color(0xFF343534)),
                    Expanded(
                      child: Video(
                        controller: twoStreamPlayback[1].controller,
                        controls: NoVideoControls,
                      ),
                    ),
                  ],
                )
              : activePlayback == null
              ? const Center(
                  child: Text(
                    'A selected stream renders here.',
                    style: TextStyle(color: Color(0xFFAAA8A2)),
                  ),
                )
              : Video(
                  controller: activePlayback!.controller,
                  controls: NoVideoControls,
                ),
        ),
      ),
    );
  }
}
