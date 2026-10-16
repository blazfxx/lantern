import AppKit

if CommandLine.arguments.contains("--self-test") {
    exit(SelfTest.run(Array(CommandLine.arguments.dropFirst())))
}
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    withExtendedLifetime(delegate) { NSApplication.shared.run() }
}
