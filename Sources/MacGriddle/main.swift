// Sources/MacGriddle/main.swift
//
// SwiftPM convention: a file named exactly `main.swift` in an executable
// target is the top-level entry point — no `@main` type is needed.
// See docs/architecture/chunks/app-shell-and-lifecycle.md §2.2.

import AppKit

let app = NSApplication.shared
// Top-level main.swift code runs synchronously on the main thread before
// any concurrency machinery starts — MainActor.assumeIsolated is the
// standard, safe way to tell the compiler that for a MainActor-isolated
// initializer called from this specific context (AppDelegate is @MainActor
// because it constructs/calls into other @MainActor types like
// StatusBarController).
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
