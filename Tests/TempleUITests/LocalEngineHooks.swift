import CoreServices
@testable import TempleCore

extension SessionEngine {
    func reconcileEvent(path: String, flags: FSEventStreamEventFlags) {
        (source as? LocalSessionSource)?.reconcileEvent(path: path, flags: flags)
    }
    func reconcileEnrichment() {
        (source as? LocalSessionSource)?.reconcileEnrichment()
    }
}
