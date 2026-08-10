import SwiftUI
import TempleCore

/// Subscription usage in the sidebar footer, read natively:
/// Claude from the OAuth usage endpoint (live), Codex from its rollout-log
/// snapshot (fresh as the last Codex turn). See SubscriptionUsage.swift for
/// the mechanics; both readers return nil on any surprise, and nil renders
/// as NOTHING — a user without a subscription (or with a changed endpoint)
/// never sees an error, just no meter.
@MainActor
public final class UsageMeterModel: ObservableObject {
    @Published private(set) var claude: ClaudeUsage?
    @Published private(set) var codex: CodexUsage?
    @Published private(set) var updatedAt: Date?
    /// When the CLAUDE numbers last actually moved. Separate from `updatedAt`,
    /// which a Codex-only success also bumps: the card needs to say how old the
    /// figures in front of you are, and a live Codex read says nothing about
    /// how long the Claude reader has been dead.
    @Published private(set) var claudeUpdatedAt: Date?
    /// True while a fetch is in flight — the card's refresh control spins.
    @Published private(set) var refreshing = false

    /// Seams for tests.
    var claudeFetch: @Sendable () async -> ClaudeUsageReader.Outcome = { await ClaudeUsageReader.read() }
    var codexFetch: @Sendable () async -> CodexUsage? = { CodexUsageReader.read() }

    /// Tripped by a no-credentials read, and it silences every AUTOMATIC poll
    /// from then on: the credential lookup is what raises the macOS Keychain
    /// prompt, so a user who clicked Deny (or has no login) must not be
    /// re-prompted every five minutes. Endpoint failures do NOT trip this —
    /// they never prompt, so retrying them silently is free.
    ///
    /// It is NOT a permanent death sentence, which is what it used to be. The
    /// lookup fails transiently too — the Keychain is locked, or Claude Code is
    /// mid-rotation and only its token-less stub items are readable — and a
    /// latch that only a relaunch could clear meant one unlucky poll froze the
    /// Claude figures for the life of the process. Measured in the wild: an
    /// eight-day-old app showing eight-day-old percentages, with a Codex
    /// section beside them updating normally. `manualRefresh()` clears it, so
    /// the refresh control is a real way out and not a spinning no-op.
    private var claudeCredentialsMissing = false
    /// Set by a 429: no Claude reads until it passes.
    private var claudeBackoffUntil: Date = .distantPast

    /// The Claude number is a live endpoint hit against an API Anthropic
    /// rate-limits — poll politely: a timer plus app activation and manual
    /// clicks, each floored so no path can hammer the endpoint.
    var refreshInterval: TimeInterval = 300
    var activationFloor: TimeInterval = 120
    var manualFloor: TimeInterval = 5
    /// How long a 429 silences the Claude reader.
    var rateLimitBackoff: TimeInterval = 3600

    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var lastAttempt: Date = .distantPast

    public init() {}

    public func start() {
        // Idempotent: RootView's `onAppear` is not once-per-launch (SwiftUI
        // re-runs it when the root view is rebuilt, e.g. the window is closed
        // and reopened), and a second call used to stack a second timer and a
        // second activation observer on top of the first — every poll then hit
        // the endpoint twice. Re-entry still refreshes, floored like activation.
        guard timer == nil else {
            refreshIfIdle(floor: activationFloor)
            return
        }
        refreshIfIdle(floor: activationFloor)   // launch: lastAttempt is distantPast
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfIdle(floor: 0) }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshIfIdle(floor: self?.activationFloor ?? 0) }
        }
    }

    /// An unattended refresh: skipped while one is already in flight, and
    /// floored so no path can hammer the endpoint.
    ///
    /// Both checks run when the task EXECUTES, not when it is queued. Queued
    /// checks let two calls in the same main-actor turn — a window rebuild
    /// landing on top of launch — each pass a test against state neither has
    /// had the chance to move yet, and two overlapping fetches are not merely
    /// wasteful: they finish in either order, so an older reading can land on
    /// top of a newer one, and a `.noCredentials` from the loser can latch the
    /// breaker over the winner's success.
    private func refreshIfIdle(floor: TimeInterval) {
        Task { @MainActor [weak self] in
            guard let self, !self.refreshing,
                  Date().timeIntervalSince(self.lastAttempt) > floor else { return }
            await self.refreshNow()
        }
    }

    /// Click-to-refresh: the meter exists because its user checks usage all
    /// day, and "the number, now" needs a mouse route. Floored, not free.
    ///
    /// `retryingCredentials` is the escape hatch from the no-credentials
    /// breaker, and ONLY the explicit refresh control passes it. Opening the
    /// card is a navigation gesture that happens to refresh on the way in; if
    /// it also retried the lookup, a user who denied the Keychain prompt would
    /// be asked again every time they looked at their usage, which is the exact
    /// nagging the breaker exists to stop. The button says "Refresh now" and is
    /// sitting right next to the line explaining that the numbers are stale, so
    /// that is where a prompt belongs.
    ///
    /// The 429 backoff survives both: that one is the server telling us to
    /// stop, and clicking harder is the wrong answer.
    public func manualRefresh(retryingCredentials: Bool = false) {
        // Re-arm before the floor check: the click re-arms the reader even on
        // the clicks that are too soon to spend a request on.
        if retryingCredentials { claudeCredentialsMissing = false }
        guard !refreshing, Date().timeIntervalSince(lastAttempt) > manualFloor else { return }
        Task { await refreshNow() }
    }

    func refreshNow() async {
        lastAttempt = Date()
        refreshing = true
        defer { refreshing = false }
        async let codexReading = codexFetch()
        var newClaude: ClaudeUsage?
        if !claudeCredentialsMissing, Date() >= claudeBackoffUntil {
            switch await claudeFetch() {
            case .usage(let usage): newClaude = usage
            case .noCredentials:
                claudeCredentialsMissing = true
                // Every one of these paths leaves stale numbers on screen, and
                // without a log the only symptom is a percentage that quietly
                // stops moving — which is exactly how this went unnoticed for
                // eight days. One line each makes it a `log show` away.
                TempleUILog.usage.info("claude usage: no credentials; automatic polls suspended until a manual refresh")
            case .rateLimited:
                claudeBackoffUntil = Date().addingTimeInterval(rateLimitBackoff)
                TempleUILog.usage.info("claude usage: rate limited; backing off \(self.rateLimitBackoff, privacy: .public)s")
            case .endpointFailure:
                TempleUILog.usage.info("claude usage: endpoint did not answer; keeping the last reading")
            }
        }
        let newCodex = await codexReading
        // Keep the last good reading through a transient failure; only a
        // fresh success moves the numbers (or reveals the meter at all).
        if newClaude != nil {
            claude = newClaude
            claudeUpdatedAt = Date()
            claudeMissedRefreshes = 0
        } else {
            claudeMissedRefreshes += 1
        }
        if newCodex != nil { codex = newCodex }
        if newClaude != nil || newCodex != nil { updatedAt = Date() }
    }

    /// Refreshes in a row that produced no Claude reading — counting the ones
    /// that never even asked, because the breaker was tripped or a 429 backoff
    /// was still running.
    ///
    /// Counting the skipped ones is the whole point. The eight-day bug failed
    /// zero times: after the latch, nothing was ever attempted, so a counter of
    /// *failures* would have sat at 1 forever while the numbers rotted. What
    /// the user cares about is not whether a request failed, it is whether the
    /// figures in front of them moved.
    @Published private(set) var claudeMissedRefreshes = 0

    /// Three in a row before the card says anything: one hiccup stays quiet, a
    /// reader that has actually stopped does not.
    static let staleAfterMissedRefreshes = 3

    /// When the on-screen Claude figures were read, once enough refreshes have
    /// come and gone without moving them; nil while they are current.
    ///
    /// The meter's whole failure mode is silence — a dead reader and a healthy
    /// one look identical, because a percentage that isn't moving is also what
    /// "you haven't used any" looks like. Codex has always carried its as-of
    /// line (its numbers are a snapshot by nature); Claude claimed to be live
    /// and had no way to say when it stopped being live.
    ///
    /// Deliberately counted, not timed. A `Date()` comparison read during view
    /// evaluation goes true at a moment nothing publishes, so an open card
    /// would keep its silence until some unrelated change redrew it.
    var claudeStaleSince: Date? {
        guard claude != nil,
              claudeMissedRefreshes >= Self.staleAfterMissedRefreshes else { return nil }
        return claudeUpdatedAt
    }

    // MARK: What the footer shows

    /// How close Claude is to ANY wall — five-hour, weekly, or a scoped
    /// (per-model) window. The glanceable number is the most constrained one.
    var claudeHeadlinePct: Int? {
        guard let claude else { return nil }
        let windows = [claude.fiveHour?.pct, claude.weekly?.pct]
            + claude.scoped.map { $0.pct }
        guard let worst = windows.compactMap({ $0 }).max() else { return nil }
        return Int(worst.rounded())
    }

    var codexHeadlinePct: Int? {
        guard let codex else { return nil }
        let windows = [codex.fiveHour?.pct, codex.weekly?.pct]
        guard let worst = windows.compactMap({ $0 }).max() else { return nil }
        return Int(worst.rounded())
    }

    /// Tooltip for the Claude segment: one window per line, headline first.
    var claudeBreakdown: String? {
        guard let claude else { return nil }
        let plan = claude.plan.map { " (\($0))" } ?? ""
        var lines = ["Claude\(plan)"]
        if let window = claude.fiveHour { lines.append("5-hour window: \(Int(window.pct.rounded()))%") }
        if let window = claude.weekly { lines.append("Weekly: \(Int(window.pct.rounded()))%") }
        for scope in claude.scoped {
            lines.append("\(scope.label): \(Int(scope.pct.rounded()))%")
        }
        if let credits = claude.creditsPct {
            lines.append("Extra-usage credits: \(Int(credits.rounded()))%")
        }
        return lines.joined(separator: "\n")
    }

    /// Tooltip for the Codex segment, with the snapshot's freshness — its
    /// numbers only move when Codex itself runs a turn.
    var codexBreakdown: String? {
        guard let codex else { return nil }
        let plan = codex.plan.map { " (\($0))" } ?? ""
        var lines = ["Codex\(plan)"]
        if let window = codex.fiveHour { lines.append("5-hour window: \(Int(window.pct.rounded()))%") }
        if let window = codex.weekly { lines.append("Weekly: \(Int(window.pct.rounded()))%") }
        if let captured = codex.capturedAt {
            lines.append("As of the last Codex turn, \(RelativeTime.string(from: captured))")
        }
        return lines.joined(separator: "\n")
    }

    deinit {
        timer?.invalidate()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }
}
