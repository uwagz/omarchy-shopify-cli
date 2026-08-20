# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.4] — 2026-08-20

### Security
- Shopify links are now built only from a validated store hostname
  (`*.myshopify.com`), a numeric theme id and an opaque client id. Previously
  a value such as `real-store.myshopify.com@evil.example.com` in a repo's
  `shopify.app.toml` produced a menu entry labelled "Store admin" that opened
  an attacker's site — a credential-phishing vector, since the dev command can
  come from the repo being worked on.
- The theme preview link honours `--host` only for loopback/private addresses;
  a routable host falls back to `127.0.0.1`.
- A session's project directory is verified to be an existing directory, so a
  repo-supplied `--path` pointing at a file can no longer be handed to
  `xdg-open` ("reveal folder"), the terminal's `--dir=`, or the fetch cwd.
- The stop helper refuses a target whose recorded start time is unknown (`0`),
  which could otherwise match a process with an unreadable `/proc` entry.
- The status/error line is rendered as plain text like every other data-bearing
  label, closing the last rich-text gap in the panel.

### Fixed
- A malformed `shopify.app.toml` (deeply nested tables → `RecursionError`) or a
  non-UTF-8 directory name no longer crashes the helper, which previously left
  the whole widget stale until restart. Output is now written as UTF-8 with
  replacement, and one unreadable session can no longer blank the others.

## [1.0.3] — 2026-08-20

### Security
- Defense-in-depth from a second review pass (no exploitable issue found):
  the background detail fetch passes its internal flags in `--flag=value` form
  (so a value starting with `-` is preserved, not dropped); the theme preview
  host is restricted to a hostname charset before building the URL; and the
  terminal launcher passes `--` before the command so a cli path can never be
  read as an `xdg-terminal-exec` option.

### Documentation
- Noted that the `sessions` IPC returns upstream strings verbatim (consume as
  data, do not render as markup).

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
