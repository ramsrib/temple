import CoreServices
@testable import TempleCore

extension SessionEngine {
    /// Delivers a filesystem event to a local source as FSEvents would.
    nonisolated func reconcileEvent(path: String, flags: FSEventStreamEventFlags) {
        (source as? LocalSessionSource)?.reconcileEvent(path: path, flags: flags)
    }
}
