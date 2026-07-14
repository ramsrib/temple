import AppKit
import SwiftUI

/// Mounts the tab strip into the native title-bar band as a titlebar accessory,
/// bypassing NSToolbar item layout entirely: NSToolbar overflows an item
/// all-or-nothing into the `»` menu once it is wider than the band, so the
/// strip can never be a toolbar item. The accessory's clip view is
/// re-constrained to span from the sidebar's trailing edge to the window's
/// right edge (the surgery Ghostty ships for titlebar tabs — see
/// Vendor/ghostty TitlebarTabsTahoeTerminalWindow), and the chips scroll
/// INSIDE that clip with a manual offset — cmux's mechanics — because a
/// SwiftUI ScrollView in the title bar either reports infinite ideal width or
/// paints a scrollbar across the band.
///
/// Placed as the detail pane's background so its own AppKit frame IS the
/// detail pane's frame: the strip's leading edge tracks the sidebar divider
/// live, with no estimated widths anywhere.
struct TitlebarTabStripInstaller: NSViewRepresentable {
    @EnvironmentObject var model: AppModel

    func makeNSView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.model = model
        return view
    }

    func updateNSView(_ view: InstallerView, context: Context) {
        view.model = model
    }

    /// Invisible view that reaches the NSWindow, installs the accessory, and
    /// reports the detail pane's leading edge on every layout pass.
    final class InstallerView: NSView {
        var model: AppModel?
        private weak var container: TabStripContainerView?

        private static let accessoryID =
            NSUserInterfaceItemIdentifier("temple.titlebarTabStrip")

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard container == nil, let window, let model else { return }
            // SwiftUI recreates this NSView when the detail pane's content
            // identity flips (launcher → terminal), so installation must be
            // idempotent PER WINDOW: adopt an accessory some earlier instance
            // installed rather than stacking a second strip over it.
            if let existing = window.titlebarAccessoryViewControllers
                .first(where: { $0.identifier == Self.accessoryID })?
                .view as? TabStripContainerView {
                container = existing
                reportLeadingEdge()
                return
            }
            let controller = NSTitlebarAccessoryViewController()
            controller.identifier = Self.accessoryID
            let strip = TabStripContainerView(model: model)
            controller.view = strip
            // Must be set BEFORE adding — AppKit asserts otherwise on Tahoe.
            controller.layoutAttribute = .right
            window.addTitlebarAccessoryViewController(controller)
            container = strip
            // The accessory's clip view only exists after AppKit has placed the
            // controller, so the first attempt may be too early — see `layout()`,
            // which keeps trying. Until the band is claimed the strip is whatever
            // `.right` gives us: fit-to-content, pinned to the window's right edge,
            // with every chip overflowed. That is a broken-looking title bar, so we
            // must never stop at one attempt.
            DispatchQueue.main.async { [weak self] in
                self?.claimBandIfNeeded()
                self?.reportLeadingEdge()
            }
        }

        override func layout() {
            super.layout()
            // Retry on every layout pass until it takes. The original one-shot
            // attempt left the strip permanently mislaid on any machine where
            // AppKit hadn't built the accessory's clip view by that single tick —
            // a cold first launch on a slower Mac was enough.
            claimBandIfNeeded()
            reportLeadingEdge()
        }

        private func claimBandIfNeeded() {
            guard let container, !container.hasClaimedBand else { return }
            container.claimTitlebarBand()
        }

        private func reportLeadingEdge() {
            guard window != nil, let container else { return }
            // This view fills the detail pane, so its window-space origin is
            // the divider's live position (sidebar drag, collapse, expand).
            container.detailMinX = convert(NSPoint.zero, to: nil).x
        }
    }
}

/// The accessory view: [pinned project switcher][ clipped, manually scrolled
/// chips ][pinned `+`]. Points not over strip content hit-test to nil, so the
/// native band keeps window-drag and double-click-zoom there.
/// In the title bar, AppKit asks the hit-tested view `mouseDownCanMoveWindow`
/// before delivering a drag — and NSHostingView (non-opaque) answers yes, so
/// a chip drag moves the WINDOW and SwiftUI's `.onDrag` session never starts.
/// Ghostty ships the same override (NonDraggableHostingView) for its titlebar
/// accessories. The empty band stays draggable: hitTest there returns nil.
private final class StripHostingView: NSHostingView<AnyView> {
    override var mouseDownCanMoveWindow: Bool { false }
}


@MainActor
final class TabStripContainerView: NSView {
    private let pinnedHost: StripHostingView
    private let chipsHost: StripHostingView
    private let trailingHost: StripHostingView
    private let leftCue: StripHostingView
    private let rightCue: StripHostingView
    private let scrollClip = NSView()

    private var chipsLeading: NSLayoutConstraint!
    /// Left edge of the re-anchored clip view; constant follows the sidebar.
    private var bandLeft: NSLayoutConstraint?
    /// Cue slot widths: 0 when that side has no hidden chips.
    private var leftCueWidth: NSLayoutConstraint!
    private var rightCueWidth: NSLayoutConstraint!

    /// Traffic lights PLUS the sidebar-toggle toolbar button, which joins
    /// them in the band while the sidebar is collapsed — the strip must
    /// start past both or the toggle renders over the project switcher.
    private static let windowButtonsInset: CGFloat = 144
    /// Breathing room between the divider/window-buttons and the switcher.
    private static let leadingGap: CGFloat = 4
    /// Gap between the last visible chip pixel and the pinned `+`, and between
    /// the `+` and the window's right edge.
    private static let trailingGap: CGFloat = 2
    private static let trailingInset: CGFloat = 16
    /// A visible cue slot's width; collapsed to 0 when that side has nothing
    /// hidden. Slightly wider than the 16pt control so the circle gets air.
    private static let cueSlotWidth: CGFloat = 18
    /// Chips run edge-to-edge in the band (browser-tab style): any inset plus
    /// the chip's own silhouette reads as a stray frame inside the title bar.
    private static let chipVerticalInset: CGFloat = 0
    private static let revealMargin: CGFloat = 12

    /// How far the chips are scrolled (0 = leading edge flush).
    private var offset: CGFloat = 0 {
        didSet {
            chipsLeading.constant = -offset
            updateOverflowCues()
        }
    }

    private var maxOffset: CGFloat {
        max(0, chipsHost.frame.width - scrollClip.bounds.width)
    }

    /// Every chip's frame in the chips row's coordinates, left to right
    /// (reported by TabStripChipsRow); what the cue clicks step across.
    var chipFrames: [CGRect] = []

    /// Detail pane's leading edge in window coordinates (set by the installer).
    var detailMinX: CGFloat = 0 {
        didSet {
            guard detailMinX != oldValue else { return }
            bandLeft?.constant = max(detailMinX, Self.windowButtonsInset) + Self.leadingGap
        }
    }

    init(model: AppModel) {
        pinnedHost = StripHostingView(rootView: AnyView(
            TabStripPinnedCluster().environmentObject(model)))
        trailingHost = StripHostingView(rootView: AnyView(
            TabStripTrailingCluster().environmentObject(model)))
        chipsHost = StripHostingView(rootView: AnyView(EmptyView()))
        leftCue = StripHostingView(rootView: AnyView(EmptyView()))
        rightCue = StripHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 38))
        chipsHost.rootView = AnyView(
            TabStripChipsRow(
                reveal: { [weak self] rect in self?.reveal(rect) },
                framesChanged: { [weak self] rects in self?.chipFrames = rects })
            .environmentObject(model))
        leftCue.rootView = AnyView(
            StripOverflowCue(edge: .leading) { [weak self] in self?.step(.left) })
        rightCue.rootView = AnyView(
            StripOverflowCue(edge: .trailing) { [weak self] in self?.step(.right) })

        for host in [pinnedHost, chipsHost, trailingHost, leftCue, rightCue] {
            host.translatesAutoresizingMaskIntoConstraints = false
            host.sizingOptions = .intrinsicContentSize
        }
        scrollClip.translatesAutoresizingMaskIntoConstraints = false
        scrollClip.clipsToBounds = true

        addSubview(pinnedHost)
        addSubview(trailingHost)
        addSubview(leftCue)
        addSubview(rightCue)
        addSubview(scrollClip)
        scrollClip.addSubview(chipsHost)
        leftCue.isHidden = true
        rightCue.isHidden = true

        chipsLeading = chipsHost.leadingAnchor.constraint(equalTo: scrollClip.leadingAnchor)
        // Each cue owns a slot in the band — [switcher][‹][chips][›][+] — that
        // collapses to zero width while its side has nothing hidden, so chips
        // never sit underneath a cue.
        leftCueWidth = leftCue.widthAnchor.constraint(equalToConstant: 0)
        rightCueWidth = rightCue.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            pinnedHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            // Full-height like the chips, so the switcher's hover fill spans
            // the band instead of floating as a pill inside it.
            pinnedHost.topAnchor.constraint(equalTo: topAnchor),
            pinnedHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftCueWidth,
            leftCue.leadingAnchor.constraint(equalTo: pinnedHost.trailingAnchor),
            leftCue.centerYAnchor.constraint(equalTo: centerYAnchor),
            scrollClip.leadingAnchor.constraint(equalTo: leftCue.trailingAnchor),
            // The clip ends where the `›` slot (then the pinned `+`) begins:
            // chips scroll between the cues, never underneath anything.
            scrollClip.trailingAnchor.constraint(equalTo: rightCue.leadingAnchor),
            scrollClip.topAnchor.constraint(equalTo: topAnchor),
            scrollClip.bottomAnchor.constraint(equalTo: bottomAnchor),
            rightCueWidth,
            rightCue.trailingAnchor.constraint(equalTo: trailingHost.leadingAnchor,
                                               constant: -Self.trailingGap),
            rightCue.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingHost.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                   constant: -Self.trailingInset),
            trailingHost.centerYAnchor.constraint(equalTo: centerYAnchor),
            chipsLeading,
            // Stretch the chips row to the band: full-height tabs, with just
            // enough margin to keep the pill silhouette.
            chipsHost.topAnchor.constraint(equalTo: scrollClip.topAnchor,
                                           constant: Self.chipVerticalInset),
            chipsHost.bottomAnchor.constraint(equalTo: scrollClip.bottomAnchor,
                                              constant: -Self.chipVerticalInset),
        ])

        // Closing tabs shrinks the content; never leave a stale over-scroll.
        chipsHost.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentFrameChanged),
            name: NSView.frameDidChangeNotification, object: chipsHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Re-anchor the accessory's clip view to span the title-bar band from the
    /// sidebar edge to the window's right edge. AppKit gives a `.right`
    /// accessory only its fitting size; these constraints override that.
    /// True once the strip spans the band. Until then it is fit-to-content at the
    /// window's right edge — the caller retries.
    private(set) var hasClaimedBand = false

    /// Re-anchor the accessory's clip view to span from the sidebar divider to the
    /// window's right edge.
    ///
    /// Two ways this used to fail silently, both leaving the title bar looking broken
    /// (project switcher jammed right, every tab overflowed into the `‹ ›` cues):
    ///
    /// - Called before AppKit had created the clip view (`superview == nil`). It was
    ///   attempted exactly once, a tick after install, so a cold launch on a slower
    ///   machine simply lost. `layout()` now retries until this returns having claimed.
    /// - The ancestor walk looks for AppKit's *private* `NSTitlebarView` by class name.
    ///   If a macOS version shapes that hierarchy differently the walk finds nothing —
    ///   and we used to give up. Now we fall back to whatever AppKit actually put the
    ///   clip view in: spanning the wrong-but-real container still beats not spanning
    ///   anything.
    func claimTitlebarBand() {
        guard !hasClaimedBand, let clipView = superview else { return }
        var ancestor: NSView? = clipView
        while let view = ancestor, !view.className.contains("NSTitlebarView") {
            ancestor = view.superview
        }
        let band: NSView
        if let titlebarView = ancestor {
            band = firstDescendant(of: titlebarView, className: "NSToolbarView") ?? titlebarView
        } else if let fallback = clipView.superview, spansTheWindow(fallback) {
            // Worth knowing about: this macOS shapes the titlebar differently than we
            // expect, and the strip is anchored to a guess. A misplaced title bar is
            // otherwise diagnosable only from a screenshot.
            TempleUILog.launch.warning("titlebar strip: NSTitlebarView not found; anchoring to \(fallback.className, privacy: .public)")
            band = fallback
        } else {
            // Nothing worth anchoring to yet. Return WITHOUT claiming, so `layout()`
            // tries again: a fallback that doesn't span the window is an
            // accessory-sized wrapper, and pinning ourselves inside it would cement
            // the very fit-to-content bug we're here to fix — permanently, since a
            // claim suppresses all future retries.
            return
        }
        hasClaimedBand = true

        clipView.translatesAutoresizingMaskIntoConstraints = false
        translatesAutoresizingMaskIntoConstraints = false

        let left = clipView.leftAnchor.constraint(
            equalTo: band.leftAnchor,
            constant: max(detailMinX, Self.windowButtonsInset) + Self.leadingGap)
        bandLeft = left
        NSLayoutConstraint.activate([
            left,
            clipView.rightAnchor.constraint(equalTo: band.rightAnchor),
            clipView.topAnchor.constraint(equalTo: band.topAnchor),
            clipView.heightAnchor.constraint(equalTo: band.heightAnchor),
            leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            topAnchor.constraint(equalTo: clipView.topAnchor),
            heightAnchor.constraint(equalTo: clipView.heightAnchor),
        ])
    }

    /// Is this view wide enough to BE the title-bar band? The band runs the width of
    /// the window; an accessory-sized wrapper does not. Without this check the
    /// fallback would happily anchor the strip inside a box the size of its own
    /// content — which looks exactly like the bug it is meant to fix.
    private func spansTheWindow(_ view: NSView) -> Bool {
        guard let window, window.frame.width > 0 else { return false }
        return view.bounds.width >= window.frame.width * 0.8
    }

    private func firstDescendant(of view: NSView, className: String) -> NSView? {
        for sub in view.subviews {
            if sub.className == className { return sub }
            if let found = firstDescendant(of: sub, className: className) { return found }
        }
        return nil
    }

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        guard maxOffset > 0 else {
            super.scrollWheel(with: event)
            return
        }
        // Dominant axis: a mostly-vertical trackpad swipe and a plain mouse
        // wheel (which has no horizontal axis) both scroll the strip sideways.
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        guard delta != 0 else { return }
        offset = min(max(0, offset - delta), maxOffset)
    }

    @objc private func contentFrameChanged() {
        if offset > maxOffset { offset = maxOffset }
        updateOverflowCues()
    }

    override func layout() {
        super.layout()
        if offset > maxOffset { offset = maxOffset }
        updateOverflowCues()
    }

    /// A cue's slot opens on a side exactly while chips are clipped past it.
    private func updateOverflowCues() {
        let showLeft = offset > 0.5
        let showRight = offset < maxOffset - 0.5
        leftCue.isHidden = !showLeft
        rightCue.isHidden = !showRight
        leftCueWidth.constant = showLeft ? Self.cueSlotWidth : 0
        rightCueWidth.constant = showRight ? Self.cueSlotWidth : 0
    }

    /// Scroll a chip (rect in the chips row's own coordinate space) into view.
    func reveal(_ rect: CGRect) {
        // A brand-new chip's frame arrives from SwiftUI before AppKit has
        // laid out the hosting view's new intrinsic width; without fresh
        // widths the clamp below under-scrolls and the chip stays hidden.
        layoutSubtreeIfNeeded()
        let clipWidth = scrollClip.bounds.width
        guard clipWidth > 0 else { return }
        var target = offset
        if rect.minX - Self.revealMargin < offset {
            target = max(0, rect.minX - Self.revealMargin)
        } else if rect.maxX + Self.revealMargin > offset + clipWidth {
            target = min(maxOffset, rect.maxX + Self.revealMargin - clipWidth)
        }
        animate(to: target)
    }

    enum StepDirection { case left, right }

    /// One cue click = the nearest still-hidden chip on that side scrolled
    /// fully into view.
    private func step(_ direction: StepDirection) {
        let clipWidth = scrollClip.bounds.width
        guard clipWidth > 0 else { return }
        switch direction {
        case .left:
            guard let chip = chipFrames.last(where: { $0.minX < offset - 0.5 }) else {
                animate(to: 0)
                return
            }
            animate(to: max(0, chip.minX - Self.revealMargin))
        case .right:
            guard let chip = chipFrames.first(where: { $0.maxX > offset + clipWidth + 0.5 }) else {
                animate(to: maxOffset)
                return
            }
            animate(to: min(maxOffset, chip.maxX + Self.revealMargin - clipWidth))
        }
    }

    private func animate(to target: CGFloat) {
        guard target != offset else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            offset = target
            scrollClip.layoutSubtreeIfNeeded()
        }
    }

    // MARK: Native band behavior

    /// Points not over actual strip content fall through to the titlebar, so
    /// the empty band keeps native window-drag and double-click-to-zoom.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let result = super.hitTest(point) else { return nil }
        if result === self || result === scrollClip { return nil }
        return result
    }
}
