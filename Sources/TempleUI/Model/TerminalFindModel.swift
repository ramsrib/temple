import Combine
import Foundation
import TempleTerminalAPI

/// Find-in-terminal for one tab (⌘F). The bar over the terminal is a view of
/// this; the surface does the matching and highlighting and reports the count
/// back through its delegate (`OpenSessionsModel` forwards it here).
///
/// Lives on the tab, not the view: the bar is torn down and rebuilt with every
/// tab switch, and a search you left open should still be there when you return.
@MainActor
public final class TerminalFindModel: ObservableObject {
    @Published public private(set) var isPresented = false
    /// What is being searched for. Set by the bar's field; a needle that
    /// arrives from the surface (⌘E "use selection for find") is already
    /// searched and is not echoed back.
    @Published public var needle = "" {
        didSet {
            guard needle != oldValue, !applyingSurfaceNeedle else { return }
            scheduleSearch()
        }
    }
    /// Match count for the current needle; `nil` while unknown.
    @Published public private(set) var total: Int?
    /// Zero-based index of the highlighted match; `nil` when none is.
    @Published public private(set) var selected: Int?
    /// Bumped when the field should take the keyboard (open, ⌘F again).
    @Published public private(set) var focusToken = 0

    weak var surface: TerminalSurface?

    /// One- and two-character needles match nearly every line of a long
    /// scrollback, and each keystroke would rerun the search — so those wait
    /// for the typing to pause. Three or more characters search on the spot.
    static let debounceBelowCount = 3
    static let debounce: Duration = .milliseconds(300)

    private var pendingSearch: Task<Void, Never>?
    private var applyingSurfaceNeedle = false
    private var focusRequested = false

    public init() {}

    // MARK: From the bar / keyboard

    /// Show the bar and put the keyboard in its field. Already open: just refocus.
    public func open() {
        isPresented = true
        focusRequested = true
        focusToken &+= 1
    }

    /// The bar asks once per focus request, so a bar rebuilt by a tab switch
    /// leaves the keyboard with the terminal.
    func consumeFocusRequest() -> Bool {
        defer { focusRequested = false }
        return focusRequested
    }

    public func next() { surface?.navigateSearch(.next) }
    public func previous() { surface?.navigateSearch(.previous) }

    /// Done: drop the highlights and hand the keyboard back to the terminal.
    public func close() {
        pendingSearch?.cancel()
        reset()
        surface?.endSearch()
        surface?.focus()
    }

    // MARK: From the surface

    func surfaceDidStart(needle: String?) {
        // A short needle still waiting out its debounce must not land after
        // this one and replace it.
        pendingSearch?.cancel()
        if let needle, !needle.isEmpty {
            total = nil
            selected = nil
            applyingSurfaceNeedle = true
            self.needle = needle
            applyingSurfaceNeedle = false
        }
        open()
    }

    /// The terminal ended the search itself (Esc while it had the keyboard).
    /// Nothing to send back — it is already gone on that side.
    func surfaceDidEnd() {
        pendingSearch?.cancel()
        reset()
    }

    func surfaceDidUpdate(total: Int?) { self.total = total }
    func surfaceDidUpdate(selected: Int?) { self.selected = selected }

    // MARK: Internals

    private func scheduleSearch() {
        pendingSearch?.cancel()
        // The counts belong to the previous needle; libghostty's reset for the
        // new one arrives asynchronously, so drop them now rather than show
        // "3/12" against text that has not been searched yet.
        total = nil
        selected = nil
        let needle = self.needle
        if needle.isEmpty {
            surface?.search("")
            return
        }
        if needle.count >= Self.debounceBelowCount {
            surface?.search(needle)
            return
        }
        pendingSearch = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.surface?.search(needle)
        }
    }

    private func reset() {
        isPresented = false
        applyingSurfaceNeedle = true
        needle = ""
        applyingSurfaceNeedle = false
        total = nil
        selected = nil
        focusRequested = false
    }
}
