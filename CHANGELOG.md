# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.2] — 2026-08-20

### Security
- Stop no longer signals a numeric pid after a separate start-time check
  (a time-of-check/time-of-use race: the pid could be reused between the
  check and the signal). It now opens a `pidfd` for the process, verifies the
  pinned process still has the session's start time, then delivers the signal
  through the fd — `pidfd_send_signal` reaches that exact process instance or
  fails, never a recycled pid. Falls back to a double-checked `kill` only on
  kernels/interpreters without pidfd.

### Documentation
- Added a Security & privacy section and corrected the detection description
  to match the hardened `/proc` matching.

## [1.0.1] — 2026-08-20

### Fixed
- Session detection now requires the process executable to be a JS runtime
  (node/bun/deno) or a `shopify` binary, and the CLI token to be argv[0] or
  argv[1]. Previously an unrelated same-user process merely carrying
  `shopify theme dev` in its arguments (an editor opening files by those
  names, a shell wrapper quoting the command) could be listed as a session —
  and therefore sent SIGINT/SIGTERM from the panel.

## [1.0.1] — 2026-08-20

### Security
- Session detection now requires the process executable to be a JS runtime
  (node/bun/deno) or a `shopify` binary, and the CLI token to be argv[0] or
  argv[1]. An unrelated same-user process merely carrying `shopify theme dev`
  in its arguments (an editor with those files open, a shell wrapper) can no
  longer be listed as a session — or sent a stop signal.
- Stop now goes through a helper that only signals when the target pid still
  has the exact start time the session was seen with, closing a pid-reuse
  race where a recycled pid could be signalled.
- Session-derived text (theme/app names, project folder, CLI errors) is
  rendered as plain text and stripped of markup, so a hostile
  `shopify.app.toml` / `theme info` value cannot inject QML rich text (which
  would let an `<img>` tag beacon out or load a local file).
- Links are opened only when they are `http(s)` URLs, and CLI flags are passed
  in `--flag=value` form so an attacker-controlled value cannot become a flag.

## [1.0.0] — 2026-08-19

First release.

### Added
- `bar-widget` plugin `uwagz.shopify-cli` with a native bag icon and count badge
- Panel listing `shopify theme dev` / `shopify app dev` sessions with store,
  theme / app details, port, project folder and live running time
- Open local preview (`t`), theme editor (`e`), share preview (`p`),
  GraphiQL (`g`), local app URL, storefront, store admin, app in admin;
  Liquid console / app logs in a terminal; link and copy menus per session
- CLI version in the header; `--theme-editor-sync` / `--live-reload` shown per session
- Stop a session with SIGINT from the panel (`x`)
- Hover tooltip, optional bar label, hide-when-idle
- `/proc`-based session discovery with detached, cached CLI detail lookups
- IPC: `toggle`, `status`, `count`, `sessions`, `refresh`
- Settings: `refreshIntervalSec`, `fetchDetails`, `showWhenIdle`, `showLabel`
