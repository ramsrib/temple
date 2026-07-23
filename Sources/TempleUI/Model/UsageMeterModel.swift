import SwiftUI
import TempleCore

/// EXPERIMENTAL — subscription usage in the sidebar footer, read natively:
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
    /// rate-limits — poll gently: a slow timer plus app activation, with a
    /// floor high enough that rapid app-switching can't add real load.
    var refreshInterval: TimeInterval = 600
    var activationFloor: TimeInterval = 300
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

    func refreshNow() async {
        lastAttempt = Date()
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

    /// The full story for the tooltip, one provider per line.
    var breakdown: String {
        var lines: [String] = []
        if let claude {
            var parts: [String] = []
            if let window = claude.fiveHour { parts.append("5h \(Int(window.pct.rounded()))%") }
            if let window = claude.weekly { parts.append("weekly \(Int(window.pct.rounded()))%") }
            for scope in claude.scoped {
                parts.append("\(scope.label) \(Int(scope.pct.rounded()))%")
            }
            if let credits = claude.creditsPct {
                parts.append("credits \(Int(credits.rounded()))%")
            }
            let plan = claude.plan.map { " (\($0))" } ?? ""
            lines.append("Claude\(plan): " + parts.joined(separator: " · "))
        }
        if let codex {
            var parts: [String] = []
            if let window = codex.fiveHour { parts.append("5h \(Int(window.pct.rounded()))%") }
            if let window = codex.weekly { parts.append("weekly \(Int(window.pct.rounded()))%") }
            let plan = codex.plan.map { " (\($0))" } ?? ""
            var line = "Codex\(plan): " + parts.joined(separator: " · ")
            if let captured = codex.capturedAt {
                line += " — as of last Codex turn (\(RelativeTime.string(from: captured)))"
            }
            lines.append(line)
        }
        if let updatedAt {
            lines.append("Updated \(RelativeTime.string(from: updatedAt)) · experimental")
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
