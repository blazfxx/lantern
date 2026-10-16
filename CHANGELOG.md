# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · Versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Changed
- New app icon, drawn as SVG (`app/AppIcon.svg`) and rendered into `app/AppIcon.iconset`.
- Engine updated to Erebus `c38a02d` (fixes HTTP 500 on strings cut mid-UTF-8-character): opens `.app` bundles directly, MCP server for reverse-engineering agents, launcher package.
- Opening an `.app` resolves its main executable for the architecture picker; *Open With → Lantern* now offers applications.
- Added `AGENTS.md` (build, test and release steps for people and AI agents).

## [0.1.0] — 2026-10-15

First release.

### Added
- Native macOS app (AppKit): a window per binary with a sidebar (procedures, names, strings, imports, exports), an assembly listing,
  a control-flow graph, pseudo-code and a hex view, plus a data inspector, cross-reference and patch panels.
- Command palette (⇧⌘P), go-to, back/forward history, rename and comments, assemble / patch / revert / export.
- Single-key navigation inside listings (`N`, `;`, `X`, `Space`, `Tab`, `G`, `P`, `A`, `U`, `B`, `F`, `/`).
- Cached analysis databases, fat-binary architecture picker, drag-and-drop and *Open With* support.
- `Lantern --self-test <binary>`: headless end-to-end checks of the engine bridge, renderers, graph layout and edits.
- Analysis engine provided by [Erebus](https://github.com/blazfxx/erebus) (Mach-O/ELF/PE; arm64/x86; decompiler).
