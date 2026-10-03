import SwiftUI
import TempleCore

/// The only default DB opener. Ordinary failures retain the existing ephemeral
/// fallback; an unknown schema must propagate before any models are constructed.
public enum AppDatabase {
    public static func open(path: URL = TempleDB.defaultPath()) throws -> TempleDB {
        do {
            return try TempleDB(path: path)
        } catch TempleDBError.newerSchema {
            throw TempleDBError.newerSchema
        } catch {
            TempleUILog.db.fault("failed to open database at \(path.path, privacy: .public), falling back to in-memory (state will not persist): \(String(describing: error), privacy: .public)")
            return try TempleDB.inMemory()
        }
    }
}

/// Shared by both @main entry points. The factory cannot run until schema
/// validation succeeds, so settings, overlays and tab restore are unreachable
/// when an update is required.
@MainActor
public final class AppStartup: ObservableObject {
    public let model: AppModel?
    public let failureMessage: String?
    public var updateRequired: Bool { failureMessage == TempleDBError.updateRequiredMessage }

    public init(openDatabase: () throws -> TempleDB = { try AppDatabase.open() },
                makeModel: (TempleDB) -> AppModel) {
        do {
            let database = try openDatabase()
            model = makeModel(database)
            failureMessage = nil
        } catch TempleDBError.newerSchema {
            model = nil
            failureMessage = TempleDBError.updateRequiredMessage
        } catch {
            model = nil
            failureMessage = error.localizedDescription
        }
    }
}

/// A full-window replacement, outside RootView and its overlays/restore tasks.
public struct StartupFailureView: View {
    private let message: String
    public init(message: String) { self.message = message }

    public var body: some View {
        VStack(spacing: 20) {
            Text(message).multilineTextAlignment(.center)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
