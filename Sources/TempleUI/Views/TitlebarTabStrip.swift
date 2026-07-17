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

    /// Whether the chips currently overflow the band. The cue GUTTERS are
    /// reserved (or not) from this alone — never from whether an arrow is
    /// visible — so a cue fading in can't change the clip width. That coupling
    /// was the flicker: the clip width fed `maxOffset`, `maxOffset` decided cue
    /// visibility, and cue visibility resized the clip, so a title-driven chip
    /// resize near the edge made the row oscillate left/right every layout pass.
    private var isScrollable = false

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeScreenNotification,
                     NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification,
                     NSWindow.didBecomeKeyNotification] {
            center.removeObserver(self, name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.removeObserver(
            self, name: NSWorkspace.didWakeNotification, object: nil)
        guard let window else { return }
        // `layout()` self-heals a dropped claim, but only when a layout pass
        // runs. After the display sleeps, changes, or a full-screen toggle,
        // nothing necessarily invalidates this view — so nudge it on those
        // events, and the re-claim happens at once instead of on the next
        // incidental pass.
        for name in [NSWindow.didChangeScreenNotification,
                     NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification,
                     NSWindow.didBecomeKeyNotification] {
            center.addObserver(self, selector: #selector(forceReclaim),
                               name: name, object: window)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(forceReclaim),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func forceReclaim() { needsLayout = true }

    /// The band we anchored the clip view to, and the clip view itself, tracked
    /// weakly so we can tell when AppKit has swapped either out from under us.
    private weak var anchoredBand: NSView?
    private weak var anchoredClipView: NSView?
    /// The span constraints from the current claim; deactivated and rebuilt on
    /// every re-claim so a stale, now-dangling set never piles up.
    private var claimConstraints: [NSLayoutConstraint] = []

    /// Re-anchor the accessory's clip view to span the title-bar band from the
    /// sidebar edge to the window's right edge. AppKit gives a `.right`
    /// accessory only its fitting size; these constraints override that.
    ///
    /// This is NOT a one-way latch. AppKit tears down and rebuilds the titlebar
    /// accessory hierarchy on discrete events — sleep/wake, display
    /// reconfiguration, full-screen transitions, and some late cold-launch
    /// layout passes — and each rebuild silently drops the span constraints and
    /// reverts the accessory to its default `.right` fit-to-content box pinned
    /// at the window's right edge (switcher jammed right, every tab overflowed).
    /// A latched `hasClaimedBand = true` made that unrecoverable, so the strip
    /// stayed broken until relaunch. Instead we re-derive whether the claim is
    /// still intact every layout pass and re-claim the instant it isn't.
    ///
    /// A claim is intact only while every load-bearing piece still holds:
    /// - the clip view is the SAME object we anchored (a rebuild makes a new one);
    /// - the clip AND this container still have autoresizing off (a rebuild flips
    ///   it back on, which is what restores AppKit's fit-to-content sizing);
    /// - the clip and the band are still in the same live window — the ONLY
    ///   spatial requirement, since the band (`NSToolbarView`) is a *sibling* of
    ///   the clip under `NSTitlebarView`, not an ancestor: a common window is what
    ///   makes our sibling-to-sibling span constraints resolvable, and demanding a
    ///   descendant relationship here would read "not claimed" the instant after a
    ///   real claim and thrash the layout; and
    /// - our span constraints are still installed AND active. The non-empty check
    ///   is load-bearing: `claimTitlebarBand()` clears `claimConstraints` up front
    ///   and, if the band lookup then misses (a transient reparent mid-rebuild),
    ///   returns leaving it empty. Without `!isEmpty`, `allSatisfy` is vacuously
    ///   true, so a claim that installed ZERO constraints would read as intact and
    ///   permanently suppress every retry — the collapsed strip, frozen.
    var hasClaimedBand: Bool {
        guard let clip = anchoredClipView, clip === superview,
              !clip.translatesAutoresizingMaskIntoConstraints,
              !translatesAutoresizingMaskIntoConstraints,
              let band = anchoredBand, let win = clip.window, win === band.window,
              !claimConstraints.isEmpty, claimConstraints.allSatisfy(\.isActive) else {
            return false
        }
        return true
    }

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
        // A prior claim's constraints are pinned to a band AppKit may have just
        // torn down; drop them before building a fresh set so dangling
        // constraints don't accumulate across rebuilds.
        NSLayoutConstraint.deactivate(claimConstraints)
        claimConstraints = []
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

        clipView.translatesAutoresizingMaskIntoConstraints = false
        translatesAutoresizingMaskIntoConstraints = false

        let left = clipView.leftAnchor.constraint(
            equalTo: band.leftAnchor,
            constant: max(detailMinX, Self.windowButtonsInset) + Self.leadingGap)
        bandLeft = left
        claimConstraints = [
            left,
            clipView.rightAnchor.constraint(equalTo: band.rightAnchor),
            clipView.topAnchor.constraint(equalTo: band.topAnchor),
            clipView.heightAnchor.constraint(equalTo: band.heightAnchor),
            leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            topAnchor.constraint(equalTo: clipView.topAnchor),
            heightAnchor.constraint(equalTo: clipView.heightAnchor),
        ]
        anchoredBand = band
        anchoredClipView = clipView
        NSLayoutConstraint.activate(claimConstraints)
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
        // Self-heal: if AppKit rebuilt the titlebar and dropped our span, this
        // re-claims; if the claim is intact it's a cheap guard check and no-op.
        claimTitlebarBand()
        if offset > maxOffset { offset = maxOffset }
        updateOverflowCues()
    }

    /// Reserve (or release) BOTH cue gutters from overflow alone, with a full
    /// gutter-pair of hysteresis so a chip resizing right at the edge can't flip
    /// the reservation — and jump the chips — on successive layout passes. The
    /// gutter width is what used to track cue visibility and feed back into the
    /// scroll math; decoupling it is the fix.
    private func updateScrollability() {
        // Don't decide against an unresolved clip. A frame-change callback can
        // fire with the chips already sized but `scrollClip` not yet laid out
        // (width 0); reconstructing `bandWidth` from that reads 0, latches
        // scrollable for any non-empty content, and — because the close
        // threshold then sits a full gutter-pair below the true band — never
        // recovers for content that actually fits. Wait for a real width.
        guard scrollClip.bounds.width > 0 else { return }
        // Reconstruct the cue-independent width (clip + whatever gutters are
        // reserved right now). Both terms come from the last resolved layout, so
        // this total is invariant as the gutters open and close — the decision
        // below can't chase its own tail.
        let bandWidth = scrollClip.bounds.width
            + leftCueWidth.constant + rightCueWidth.constant
        let content = chipsHost.frame.width
        if isScrollable {
            // Only give the gutters back once the content clears the band by the
            // whole reservation, so we don't immediately re-enter scrollable.
            if content <= bandWidth - 2 * Self.cueSlotWidth { isScrollable = false }
        } else if content > bandWidth {
            isScrollable = true
        }
        let gutter = isScrollable ? Self.cueSlotWidth : 0
        if leftCueWidth.constant != gutter { leftCueWidth.constant = gutter }
        if rightCueWidth.constant != gutter { rightCueWidth.constant = gutter }
    }

    /// Fade a cue in exactly while chips are clipped past its side. This toggles
    /// only visibility, never width — the gutter is already reserved by
    /// `updateScrollability`, so showing an arrow leaves the clip width untouched.
    private func updateOverflowCues() {
        updateScrollability()
        leftCue.isHidden = !(isScrollable && offset > 0.5)
        rightCue.isHidden = !(isScrollable && offset < maxOffset - 0.5)
    }

    /// Scroll a chip (rect in the chips row's own coordinate space) into view.
    func reveal(_ rect: CGRect) {
        // A brand-new chip's frame arrives from SwiftUI before AppKit has
        // laid out the hosting view's new intrinsic width; without fresh
        // widths the clamp below under-scrolls and the chip stays hidden.
        layoutSubtreeIfNeeded()
        // The new chip may have just tipped the row into scrollable, opening the
        // gutters — but their width lands on the NEXT pass, so the clip below
        // would still read its pre-gutter (36pt wider) bounds and under-scroll,
        // leaving this very chip clipped with no retry. Settle the reservation,
        // then resolve the clip to its real width before measuring.
        updateScrollability()
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
