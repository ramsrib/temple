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
    /// True while a fetch is in flight — the card's refresh control spins.
    @Published private(set) var refreshing = false

    /// Seams for tests.
    var claudeFetch: @Sendable () async -> ClaudeUsageReader.Outcome = { await ClaudeUsageReader.read() }
    var codexFetch: @Sendable () async -> CodexUsage? = { CodexUsageReader.read() }

    /// Tripped by a no-credentials read and never reset within the run: the
    /// credential lookup is what raises the macOS Keychain prompt, so a user
    /// who clicked Deny (or has no login) must not be re-prompted every poll.
    /// Endpoint failures do NOT trip this — they never prompt, so retrying
    /// them silently is free. Relaunch retries once.
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
        Task { await refreshNow() }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in await self?.refreshNow() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                guard let self,
                      Date().timeIntervalSince(self.lastAttempt) > self.activationFloor
                else { return }
                await self.refreshNow()
            }
        }
    }

    /// Click-to-refresh: the meter exists because its user checks usage all
    /// day, and "the number, now" needs a mouse route. Floored, not free.
    public func manualRefresh() {
        guard Date().timeIntervalSince(lastAttempt) > manualFloor else { return }
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
            case .noCredentials: claudeCredentialsMissing = true
            case .rateLimited: claudeBackoffUntil = Date().addingTimeInterval(rateLimitBackoff)
            case .endpointFailure: break
            }
        }
        let newCodex = await codexReading
        // Keep the last good reading through a transient failure; only a
        // fresh success moves the numbers (or reveals the meter at all).
        if newClaude != nil { claude = newClaude }
        if newCodex != nil { codex = newCodex }
        if newClaude != nil || newCodex != nil { updatedAt = Date() }
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
