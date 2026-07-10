import AppKit
import TempleTerminal
import TempleTerminalAPI

// terminal-demo — a permanent dev harness for Track T (like `templectl` is for
// TempleCore). Opens one window with one libghostty-backed TerminalSurface
// running a command (default: $SHELL; or pass an argv, e.g.
// `swift run terminal-demo claude --resume <id>`).
//
// It exercises the *production* TerminalSurface path (GhosttyTerminalSurfaceFactory),
// so a green demo == the fuse is ready. Un-bundled, it sets GHOSTTY_RESOURCES_DIR
// to the ghostty checkout (T7) so terminfo/shaders/shell-integration resolve.

// MARK: - Resources (T7): point libghostty at the checkout's installed resources.
func configureResourcesDir() {
    if let existing = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"],
       !existing.isEmpty {
        return
    }
    // Repo root, derived from this source file at compile time:
    //   <repo>/Sources/terminal-demo/main.swift → <repo>
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // terminal-demo
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // repo root
    let candidates = [
        repoRoot.appendingPathComponent("Vendor/ghostty/zig-out/share/ghostty"),
    ]
    for dir in candidates where FileManager.default.fileExists(atPath: dir.path) {
        setenv("GHOSTTY_RESOURCES_DIR", dir.path, 1)
        NSLog("[terminal-demo] GHOSTTY_RESOURCES_DIR=\(dir.path)")
        return
    }
    NSLog("[terminal-demo] WARNING: no ghostty resources dir found; terminfo/shell-integration may be missing")
}

// MARK: - App delegate
final class DemoAppDelegate: NSObject, NSApplicationDelegate, TerminalSurfaceDelegate {
    var window: NSWindow!
    var surface: TerminalSurface!

    let argv: [String]
    let cwd: String
    let autoQuitSeconds: Double?

    init(argv: [String], cwd: String, autoQuitSeconds: Double?) {
        self.argv = argv
        self.cwd = cwd
        self.autoQuitSeconds = autoQuitSeconds
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let factory = GhosttyTerminalSurfaceFactory()
        let scheme: TerminalAppearance.ColorScheme =
            (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) ? .dark : .light
        let appearance = TerminalAppearance(fontSize: 13, colorScheme: scheme)
        surface = factory.makeSurface(appearance: appearance)
        surface.delegate = self

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Temple terminal-demo"
        window.center()

        let host = surface.view
        host.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.topAnchor.constraint(equalTo: content.topAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        do {
            NSLog("[terminal-demo] starting: argv=\(argv) cwd=\(cwd)")
            try surface.start(TerminalCommand(argv: argv, cwd: cwd))
            NSLog("[terminal-demo] surface.start OK — libghostty surface created (ADR-003 validated)")
        } catch {
            NSLog("[terminal-demo] FATAL: surface.start failed: \(error)")
            NSApp.terminate(nil)
            return
        }

        window.makeFirstResponder(host)
        surface.focus()

        if let secs = autoQuitSeconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                NSLog("[terminal-demo] auto-quit after \(secs)s")
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // TerminalSurfaceDelegate
    func surface(_ surface: TerminalSurface, didChangeState state: TerminalProcessState) {
        NSLog("[terminal-demo] state: \(state)")
        if case .exited = state {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
    }
    func surface(_ surface: TerminalSurface, didUpdateTitle title: String) {
        NSLog("[terminal-demo] title: \(title)")
        window?.title = title.isEmpty ? "Temple terminal-demo" : title
    }
    func surfaceDidRing(_ surface: TerminalSurface) { NSLog("[terminal-demo] bell") }
    func surface(_ surface: TerminalSurface, didPostNotification title: String, body: String) {
        NSLog("[terminal-demo] notification: \(title) — \(body)")
    }
}

// MARK: - Entry
configureResourcesDir()

var args = Array(CommandLine.arguments.dropFirst())
let cwd = FileManager.default.currentDirectoryPath
let autoQuit = ProcessInfo.processInfo.environment["TEMPLE_DEMO_TIMEOUT"].flatMap(Double.init)

let argv: [String]
if args.isEmpty {
    argv = [ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"]
} else {
    argv = args
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = DemoAppDelegate(argv: argv, cwd: cwd, autoQuitSeconds: autoQuit)
    app.delegate = delegate
    app.run()
}
