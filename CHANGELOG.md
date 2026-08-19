# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] — 2026-08-20

### Fixed
- Session detection now requires the process executable to be a JS runtime
  (node/bun/deno) or a `shopify` binary, and the CLI token to be argv[0] or
  argv[1]. Previously an unrelated same-user process merely carrying
  `shopify theme dev` in its arguments (an editor opening files by those
  names, a shell wrapper quoting the command) could be listed as a session —
  and therefore sent SIGINT/SIGTERM from the panel.

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
