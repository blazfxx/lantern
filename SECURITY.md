# Security policy

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private reporting: **Security → Report a vulnerability**
(<https://github.com/blazfxx/lantern/security/advisories/new>). Include the version (*Lantern → About*), what you did, and — for crashes —
a minimal input file. Expect an acknowledgement within a few days.

Problems in the analysis engine (loaders, analyzer, decompiler) may also be reported at <https://github.com/blazfxx/erebus/security>.

## Scope & design

Lantern opens untrusted binaries, so the interesting bugs are crashes, hangs, memory exhaustion and anything that could make the app run
code or write files on a binary's behalf. By design:

- Analysis is **static**: the analysed binary is never executed.
- Each window talks to its own engine process over **loopback only**; the engine exits if the app exits.
- Hostile input can at worst crash that engine process, not the app.
- *Export patched binary* writes only where you choose; Mach-O output is ad-hoc signed with `codesign`.

Only the latest release receives fixes while the project is pre-1.0. Use Lantern on software you own or may analyse.
