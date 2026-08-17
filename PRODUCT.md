# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Stack

Delegated: build the first version as a Flutter/Dart application with a local SQLite catalog and a native playback package that supports Windows now and Android TV, Fire TV, and macOS later. Keep the first implementation in Dart; introduce a Rust core only if measurements from the real Strong IPTV catalog demonstrate a need.

## Users

Wabbit TV is first for its maintainer's own daily use, then for enthusiast Windows users and ordinary nontechnical households who want an IPTV player that feels organized and intentional. It must work equally well at a desk with mouse and keyboard and from a couch with a TV remote.

## Product Purpose

Wabbit TV is a content-neutral IPTV player. Users connect their own providers and turn very large, poorly organized live TV, movie, and series catalogs into a personal, coherent viewing library. Success means that a real Strong IPTV account with tens of thousands of items can be added, organized, searched, browsed, and played without the clutter and low-quality presentation common to existing Windows IPTV players.

## Positioning

Wabbit TV's differentiator is user-owned organization: sources remain manageable, provider catalogs can be viewed separately or together, genuine duplicates can share one library identity, and users can create ordered custom groups that mix channels, movies, and series and pin them to Home.

## Operating Context

- Initial target: Windows 11.
- Primary test source: the maintainer's Strong IPTV account, using a server URL, username, and password.
- Supported source forms: Xtream credentials, M3U URL, and local M3U file.
- Catalog scale: tens of thousands of live channels, movies, series, seasons, and episodes.
- Initial interaction: mouse and keyboard plus TV remote.
- The application supplies no playlists, channels, movies, series, or other content.

## Capabilities and Constraints

- Public, noncommercial, open-source project licensed AGPL-3.0.
- Initial library includes Live, Movies, and Series.
- Multiple sources can be viewed independently or in a unified catalog.
- High-confidence duplicates may merge while preserving their underlying source variants; ambiguous matches must remain separate.
- Favorites and ordered custom groups are first-class. A custom group can mix channels, movies, and series and can be pinned to Home.
- Required playback features include picture-in-picture and multiview.
- Startup behavior is user-selectable: Home, the previous screen, or the last channel.
- Everything is local. The application makes no network calls except to sources explicitly configured by the user.
- The simultaneous-stream allowance of the current Strong account is unknown. Wabbit should use a provider-reported limit when available and otherwise behave conservatively while allowing an explicit local override.
- Preserve a path to Android TV, Fire TV, and macOS, but do not implement or validate those platforms during the Windows-first phases unless the plan explicitly reaches them.
- Do not build commercial licensing, payments, cloud accounts, telemetry, a plugin platform, or distribution infrastructure.
- Engineering must be proportional: make supported workflows correct and maintainable, protect credentials from obvious leakage, and handle realistic failures. Do not add speculative abstractions, security theater, or a web of defensive branches for hypothetical edge cases.

## Brand Commitments

- Product name: Wabbit TV.
- The interface should meet the clarity and craft bar of Hulu Live TV, YouTube TV, and Netflix without copying their trade dress.
- The viewing experience is premium and restrained. Rabbit personality belongs in the application icon, onboarding, loading, and empty states rather than dominating the main interface.
- Imported artwork should carry most of the visual color; the interface itself should remain calm and television-friendly.

## Evidence on Hand

- A real Strong IPTV account is available for later local testing. Credentials are not project documentation and must not be committed.
- Fred TV Next is an AGPL-3.0 public reference for Xtream, M3U, SQLite, Flutter, and playback behavior. Wabbit TV is a fresh project and should borrow only when reuse clearly reduces work.
- No original Wabbit visual assets or incumbent interface exist yet.

## Product Principles

1. Organization is the product: sources, favorites, custom groups, and unified browsing must remain understandable and under user control.
2. Viewing comes first: navigation and playback should feel fast, calm, and intentional from both desk and couch.
3. Local and content-neutral: Wabbit supplies no content, creates no account, and sends no telemetry.
4. Measure before adding machinery: optimize the real large catalog and introduce complexity only when evidence requires it.
5. Stay on the recorded plan: finish the current phase's acceptance criteria before expanding scope.

## Accessibility & Inclusion

All primary workflows must be usable without a mouse. Remote and keyboard navigation require predictable directional focus, a visible but visually integrated focus state, reliable Back/Escape behavior, readable type at television distance, and no hover-only actions.
