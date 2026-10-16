# Architecture

Lantern is deliberately thin: a native macOS front end over the [Erebus](https://github.com/blazfxx/erebus) engine.

```
 Lantern.app (Swift / AppKit)                         erebus (C++ engine, bundled as Contents/Resources/bin/erebus)
 ┌─────────────────────────────────────┐   JSON/HTTP  ┌──────────────────────────────────────────────┐
 │ DocumentWindowController            │ ───────────► │ loaders → analysis → .erdb → decompiler       │
 │  sidebar · listing · graph · pseudo │  127.0.0.1   │ `erebus serve <db> --port 0 --watch-pid <app>` │
 └─────────────────────────────────────┘ ◄─────────── └──────────────────────────────────────────────┘
```

- **One engine process per window.** The app runs `erebus open` once (cached in `~/Library/Application Support/Lantern/Databases`),
  then `erebus serve` on a random loopback port. `--watch-pid` makes the engine exit by itself if the app dies.
- **`EngineAPI.swift`** is the typed client (`Codable` models mirror the engine's JSON).
- **`Renderers.swift`** turns JSON into attributed text and is pure — no views — so it is covered by the self-test.
- **`CFG.swift`** has the layered graph layout (`CFGLayouter`, pure) and `CFGView`, which draws with Core Graphics.
- **`CodeView.swift`** is a TextKit 1 text view with clickable symbols, line highlighting and single-key commands.
- **`Sidebar`, `Inspector`, `Palette`** are the AppKit panels; **`DocumentWindow.swift`** wires everything and owns navigation state.
- **`SelfTest.swift`** runs the same code paths headlessly: `Lantern --self-test <binary>`.

## Why a separate engine process?

It keeps the UI responsive (analysis never blocks the main thread), isolates crashes caused by hostile binaries from the app,
and lets the same engine serve a browser UI, a CLI and a Python client.
