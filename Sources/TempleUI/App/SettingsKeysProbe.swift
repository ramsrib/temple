import AppKit

/// Dev-only (`TEMPLE_SNAPSHOT_DIR` + `TEMPLE_SNAPSHOT_PRESENT=settings-keys`):
/// proves Settings' own key handling fires in the real app — the font-size
/// field's ↑/↓ and a field's Esc-revert. Both are SwiftUI modifiers on a
/// TextField whose AppKit field editor sees every key first, so a unit test of
/// the draft model says nothing about whether a real key ever reaches them.
///
/// The keys are delivered IN-PROCESS: `NSWindow.sendEvent` with events built
/// here, to this window's first responder — the path AppKit takes for a real
/// key once it has been routed to the window. Never CGEvent, never the system
/// event stream: nothing outside this process sees them (AGENTS.md). A
/// snapshot run never activates the app, so the window is not key (the log
/// says `key=false`); `sendEvent` still hands the key to the field editor that
/// is first responder, which is the part under test.
///
/// Seen 2026-10-02: ↑↑ took the size 14 → 16, ↓ to 15; Esc emptied a typed
/// Command draft, and leaving the field afterwards committed nothing. The
/// SwiftUI modifiers do fire through the field editor; no AppKit routing needed.
///
/// Each step logs to stderr and writes a snapshot (`snapshot-NN.png`), so the
/// run is judged from what the page showed, not from what the probe believes.
///
/// It commits values (the size steps write the font size), so a run of it
/// gets a scratch defaults domain (`scratchDefaults`), cleared at launch:
/// nothing it does reaches the real preferences.
@MainActor
enum SettingsKeysProbe {
    static let mode = "settings-keys"
    private static let suite = "com.sriramb.temple.snapshot.settings-keys"

    /// A cleared scratch defaults domain when this probe is the snapshot run's
    /// mode; nil otherwise (the real `.standard`).
    static func scratchDefaults() -> UserDefaults? {
        let env = ProcessInfo.processInfo.environment
        guard !(env["TEMPLE_SNAPSHOT_DIR"] ?? "").isEmpty, env["TEMPLE_SNAPSHOT_PRESENT"] == mode else { return nil }
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)
    }

    static func run(model: AppModel) {
        model.openSessions.openSettings()
        let steps: [(TimeInterval, () -> Void)] = [
            (1.0, { focus(.fontSize) }),
            (1.4, {
                log("size field before ↑↑", model)
                press(.up); press(.up)
            }),
            (1.8, {
                log("size field after ↑↑", model)
                WindowSnapshot.captureNow()            // 01: size stepped twice
            }),
            (2.1, { focus(.command(.claude)) }),
            (2.5, { type("/tmp/draft") }),
            (2.9, {
                log("command field after typing", model)
                WindowSnapshot.captureNow()            // 02: the draft, uncommitted
                press(.escape)
            }),
            (3.3, {
                log("command field after Esc", model)
                WindowSnapshot.captureNow()            // 03: reverted, nothing committed
                // Leaving a field commits its draft: had Esc only reset the
                // field editor's text and left the draft, this would write it.
                focus(.fontSize)
            }),
            (3.7, { press(.down) }),
            (4.0, {
                log("size field after ↓, Command left", model)   // claudePath still ""
                WindowSnapshot.captureNow()            // 04: 15 pt, Command empty
            }),
        ]
        for (delay, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { step() }
        }
    }

    // MARK: Delivery

    private static var window: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey }
    }

    private static func focus(_ field: SettingsField) {
        // Through the page's own @FocusState, as a click or Tab would land.
        NotificationCenter.default.post(name: .templeDebugFocusSettingsField, object: field)
    }

    private enum Key {
        case up, down, escape, character(Character)

        var keyCode: UInt16 {
            switch self {
            case .up: return 126
            case .down: return 125
            case .escape: return 53
            case .character(let c): return Self.ansiCodes[c] ?? 0
            }
        }

        var characters: String {
            switch self {
            case .up: return String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
            case .down: return String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
            case .escape: return "\u{1b}"
            case .character(let c): return String(c)
            }
        }

        var flags: NSEvent.ModifierFlags {
            switch self { case .up, .down: return [.numericPad, .function]; default: break }
            return []
        }

        private static let ansiCodes: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "e": 14, "r": 15, "t": 17,
            "o": 31, "i": 34, "p": 35, "l": 37, "n": 45, "m": 46, "/": 44, "-": 27,
        ]
    }

    private static func press(_ key: Key) {
        guard let window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: key.flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: key.characters,
                                               charactersIgnoringModifiers: key.characters,
                                               isARepeat: false, keyCode: key.keyCode) else { continue }
            window.sendEvent(event)
        }
    }

    private static func type(_ text: String) {
        for c in text { press(.character(c)) }
    }

    private static func log(_ step: String, _ model: AppModel) {
        let responder = window?.firstResponder
        let editor = responder as? NSTextView
        let line = "settings-keys: \(step): key=\(window?.isKeyWindow ?? false)"
            + " responder=\(responder.map { String(describing: Swift.type(of: $0)) } ?? "nil")"
            + " text=\"\(editor?.string ?? "?")\""
            + " store.fontSize=\(model.settings.fontSize) store.claudePath=\"\(model.settings.claudePath)\"\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
