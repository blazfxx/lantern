# Lantern: how to build, test and release (for AI agents and people)

Lantern is a native macOS disassembler (Swift + AppKit) on the Erebus engine (`engine/` is a git submodule of
[blazfxx/erebus](https://github.com/blazfxx/erebus)). Apple silicon, macOS 13+.

## Where you can build

- **On a Mac:** `brew install cmake ninja capstone cpp-httplib nlohmann-json`, then
  `git clone --recurse-submodules https://github.com/blazfxx/lantern && cd lantern`.
  - `scripts/test.sh` builds the engine and a test copy of the app and runs `Lantern --self-test` on real binaries.
  - `scripts/build-app.sh [--zip] [--dmg]` makes `dist/Lantern.app` (ad-hoc signed; the zip/dmg are named `Lantern-<VERSION>-macos-arm64.*`).
  - Optional: `brew install keystone` enables Assemble Instruction (loaded at run time, not bundled: GPL).
- **On Linux (the VPS) you cannot compile the Swift app.** Push to `main` and read the macOS CI run:
  `gh run list -R blazfxx/lantern`, then `gh run view <id> --log-failed`. CI (`.github/workflows/ci.yml`, macos-14) runs
  `scripts/test.sh` and `scripts/build-app.sh --zip`.
- Always `git submodule update --init` first; `engine/` empty means the build stops with a message.

## Layout

- `app/Sources/*.swift`: the app (AppDelegate, DocumentWindow, CodeView, CFG, Renderers, Sidebar, Inspector, Palette, EngineAPI, SelfTest).
  `EngineAPI.swift` talks to the engine's `erebus serve` over local HTTP; `SelfTest.swift` is what `--self-test` runs.
- `app/Info.plist.in`: `@VERSION@` is filled from `VERSION`.
- `scripts/`: `build-app.sh`, `test.sh`, `render-icon.mjs`.
- `docs/`: `ARCHITECTURE.md`, screenshots, `icon.png`.

## Releasing

1. Bump `VERSION` and `CHANGELOG.md`; commit; push to `main`; wait for CI to pass.
2. `git tag vX.Y.Z && git push origin vX.Y.Z`. The Release workflow builds the zip and dmg and publishes them.
3. To pick up engine changes: `git -C engine pull origin main`, commit the submodule pointer, and run CI.

## Icon

Drawn in `app/AppIcon.svg` (the same drawing as `LanternIcon` in the Blobby repo, `packages/brand`) and rendered to
`app/AppIcon.iconset` by `scripts/render-icon.mjs`:
`PLAYWRIGHT=<playwright-core/index.mjs> CHROME=<chrome> node scripts/render-icon.mjs`, then copy the 512@2x file to `docs/icon.png`.
`build-app.sh` turns the iconset into `.icns` with `iconutil`.

## Gotchas

- Build and sign in a scratch directory (the script does): iCloud-synced folders attach Finder metadata and `codesign` fails with "detritus not allowed".
- Swift is compiled with `-swift-version 5`; keep cross-thread helpers `Sendable`-correct for older toolchains.
- Not notarized: first launch needs right-click, Open, or `xattr -dr com.apple.quarantine`.
- In the Blobby Launcher, Lantern is listed as "coming soon" (`UPCOMING` in `@blob/brand`). When it ships as a launcher package it
  would reuse the Erebus package (see the Erebus repo's `scripts/build-package.sh` and `docs/DECISIONS.md` D101 in the Blobby repo).
