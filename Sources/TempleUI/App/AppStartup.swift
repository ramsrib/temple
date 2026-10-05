import SwiftUI
import TempleCore

/// The only default DB opener. Every failure propagates before any model is
/// constructed: an unknown schema to the update-required window, anything
/// else to a window that says the data could not be opened. There is no
/// in-memory fallback — a Temple that silently forgets every tab, pin and
/// session it is given looks like it works and loses the user's work.
public enum AppDatabase {
    public static func open(path: URL = TempleDB.defaultPath()) throws -> TempleDB {
        do {
            return try TempleDB(path: path)
        } catch TempleDBError.newerSchema {
            throw TempleDBError.newerSchema
        } catch {
            TempleUILog.db.fault("failed to open database at \(path.path, privacy: .public): \(String(describing: error), privacy: .public)")
            throw AppDatabaseError.openFailed(path: path.path, reason: Self.reason(error))
        }
    }

    private static func reason(_ error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        return String(describing: error)
    }
}

public enum AppDatabaseError: Error, Equatable, LocalizedError {
    case openFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let reason):
            "Temple couldn't open its data. Nothing was changed; quit and reopen Temple to try again.\n\n\(path)\n\(reason)"
        }
    }
}

/// Why startup stopped before any model existed, in the words its window
/// uses. The raw error is kept as the details, never paraphrased (AGENTS.md).
public enum StartupFailure: Equatable {
    /// A newer Temple migrated the database past this build's schema.
    case updateRequired
    /// Anything else. `path` is nil only when the failure carried none.
    case openFailed(path: String?, reason: String)

    public var symbol: String {
        switch self {
        case .updateRequired: "arrow.down.app"
        case .openFailed: "exclamationmark.triangle"
        }
    }

    public var title: String {
        switch self {
        case .updateRequired: "Update Temple to continue"
        case .openFailed: "Temple couldn't open its data"
        }
    }

    public var message: String {
        switch self {
        case .updateRequired:
            "A newer Temple has already upgraded your session data. This version can't read it safely, so nothing was changed."
        case .openFailed:
            "Nothing was changed. Quit and open Temple again. If this keeps happening, the file below may be locked, unreadable or damaged."
        }
    }

    /// The monospaced, selectable block. For an update, which copy is running
    /// (a stale one in Downloads is the likely story); for an open failure, the
    /// path, then SQLite's own line as it came.
    public func details(version: String?, bundlePath: String) -> String? {
        switch self {
        case .updateRequired:
            return ["Temple \(version ?? "(development build)")", bundlePath].joined(separator: "\n")
        case .openFailed(let path, let reason):
            return [path, reason].compactMap { $0 }.joined(separator: "\n")
        }
    }

    /// What Reveal in Finder shows: the file when it exists, else its folder —
    /// and nothing when the folder is gone too, so the button is not offered.
    public func revealURL(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL? {
        guard case .openFailed(let path?, _) = self else { return nil }
        let file = URL(fileURLWithPath: path)
        if fileExists(file.path) { return file }
        let folder = file.deletingLastPathComponent()
        return fileExists(folder.path) ? folder : nil
    }
}

/// Shared by both @main entry points. The factory cannot run until schema
/// validation succeeds, so settings, overlays and tab restore are unreachable
/// when an update is required.
@MainActor
public final class AppStartup: ObservableObject {
    public let model: AppModel?
    public let failure: StartupFailure?
    public var updateRequired: Bool { failure == .updateRequired }

    public init(openDatabase: () throws -> TempleDB = { try AppDatabase.open() },
                makeModel: (TempleDB) -> AppModel) {
        do {
            let database = try openDatabase()
            model = makeModel(database)
            failure = nil
        } catch TempleDBError.newerSchema {
            model = nil
            failure = .updateRequired
        } catch AppDatabaseError.openFailed(let path, let reason) {
            model = nil
            failure = .openFailed(path: path, reason: reason)
        } catch {
            model = nil
            failure = .openFailed(path: nil, reason: error.localizedDescription)
        }
    }
}

/// The menu bar for whichever window startup produced. A failure window has
/// no model and so no Temple commands — but SwiftUI's default File ▸ New
/// Window (⌘N) would still open a second copy of it. Shared by both entry
/// points, like `StartupRootView`.
public struct StartupCommands: Commands {
    private let startup: AppStartup
    public init(startup: AppStartup) { self.startup = startup }

    public var body: some Commands {
        if let model = startup.model {
            TempleCommands(model: model)
        } else {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Keeps the scene's root concrete while choosing the validated startup content.
/// A conditional directly in WindowGroup prevented the bundled app from opening
/// its initial window. Keep the branch here; check-startup-windows.sh exercises
/// both paths through the real bundled app's scene lifecycle.
public struct StartupRootView: View {
    private let startup: AppStartup
    private let appDelegate: TempleAppDelegate
    private let activateOnStart: Bool

    public init(startup: AppStartup, appDelegate: TempleAppDelegate,
                activateOnStart: Bool = false) {
        self.startup = startup
        self.appDelegate = appDelegate
        self.activateOnStart = activateOnStart
    }

    public var body: some View {
        Group {
            if let model = startup.model {
                RootView()
                    .environmentObject(model)
                    .task {
                        appDelegate.model = model
                        // The archive sweep is the app's alone (ADR-030):
                        // models built by tests and tools never run it.
                        model.enableArchiveSweep()
                        model.start()
                        // Snapshot runs must not take focus from the user's work.
                        if activateOnStart,
                           ProcessInfo.processInfo.environment["TEMPLE_SNAPSHOT_DIR"] == nil {
                            NSApplication.shared.activate()
                        }
                    }
                    .frame(minWidth: 900, minHeight: 600)
            } else {
                StartupFailureView(failure: startup.failure ?? .openFailed(path: nil, reason: "Unable to open Temple."))
            }
        }
    }
}

/// A window of its own, outside RootView and its overlays/restore tasks:
/// what stopped, what was (not) touched, the raw facts selectable and
/// copyable for a bug report, and one way out. There is no model behind it,
/// so its close button and ⌘W quit through `TempleAppDelegate` like the main
/// window's (`applicationShouldTerminateAfterLastWindowClosed`).
public struct StartupFailureView: View {
    private let failure: StartupFailure
    private let details: String?
    private let revealURL: URL?

    public init(failure: StartupFailure) {
        self.failure = failure
        let bundlePath = (Bundle.main.bundleURL.path as NSString).abbreviatingWithTildeInPath
        details = failure.details(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                                  bundlePath: bundlePath)
        revealURL = failure.revealURL()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: failure.symbol)
                    .font(.system(size: 32))
                    .foregroundStyle(failure == .updateRequired ? Color.accentColor : Color.orange)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 8) {
                    Text(failure.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(failure.message)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let details {
                        Text(details)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Palette.surfaceFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.hairline))
                            .padding(.top, 4)
                    }
                }
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                if let revealURL {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([revealURL]) }
                }
                if failure != .updateRequired, let details {
                    Button("Copy Details") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(details, forType: .string)
                    }
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 340)
        .navigationTitle("Temple")
        // The dev-only snapshot override (TEMPLE_SNAPSHOT_APPEARANCE), which
        // otherwise lives in the model this window does not have.
        .preferredColorScheme(AppModel.forcedTheme?.colorScheme)
    }
}
