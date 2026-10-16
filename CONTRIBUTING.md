# Contributing to Lantern

Bug reports, UI polish, docs and code are welcome. Analysis problems (wrong disassembly/decompilation, loader crashes) usually belong in the
[Erebus](https://github.com/blazfxx/erebus) repository, which holds the engine; UI problems belong here.

## Setup

```sh
git clone --recurse-submodules https://github.com/blazfxx/lantern && cd lantern
brew install cmake ninja capstone cpp-httplib nlohmann-json     # engine build deps (+ keystone for Assemble)
scripts/test.sh            # builds engine + app binary, runs `Lantern --self-test` on real binaries
scripts/build-app.sh       # -> dist/Lantern.app
```

Requires macOS 13+, Xcode command-line tools (Swift 5.9+). Forgot `--recurse-submodules`? `git submodule update --init`.

## Pull requests

- Keep them focused and explain *why*. UI changes: include a screenshot.
- New behaviour that doesn't need a window should be reachable from `SelfTest.swift` — add a check.
- Run `scripts/test.sh` before opening the PR.
- Style: plain AppKit, no third-party Swift packages without discussion; follow `.editorconfig`.
- Licensing: Lantern is MIT. Don't add GPL code, and don't copy code or assets from other disassemblers.

By contributing you agree your work is licensed under the [MIT license](LICENSE).
