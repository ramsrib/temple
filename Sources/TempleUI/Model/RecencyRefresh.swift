import Foundation
import Combine

/// A visible consumer's own refresh for activity. After the rank freeze,
/// AppModel publishes no recency-only change (B9): the rail draws no
/// recency, and a publish per touch re-rendered the window about once a
/// second per working agent. A surface that does show recency — the
/// launcher's recent projects, the archive's order and times, the open
/// palette — watches `rowChanges` itself while it is on screen, recomputes
/// what it shows at most once per main-queue turn, and bumps `revision`
/// only when that differs. Only the watching view redraws.
@MainActor
final class RecencyRefresh: ObservableObject {
    /// Bumped when the watched presentation changed.
    @Published private(set) var revision = 0
    private var cancellable: AnyCancellable?
    private var presentation: (() -> AnyHashable)?
    private var shown: AnyHashable?
    private var scheduled = false

    /// Start (or restart) watching: `presentation` is what the surface shows
    /// that activity can change, as it shows it now.
    func watch(_ overlay: SessionOverlayStore, presentation: @escaping () -> AnyHashable) {
        self.presentation = presentation
        shown = presentation()
        cancellable = overlay.rowChanges
            .filter(\.recencyOnly)
            .sink { [weak self] _ in self?.changed() }
    }

    private func changed() {
        guard !scheduled else { return }
        scheduled = true
        // A turn later: every subscriber, AppModel's current values included,
        // has taken the change by then.
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.check() } }
    }

    private func check() {
        scheduled = false
        guard let presentation else { return }
        let next = presentation()
        guard next != shown else { return }
        shown = next
        revision &+= 1
    }
}
