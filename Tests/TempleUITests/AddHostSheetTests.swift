import AppKit
import SwiftUI
import XCTest
import TempleCore
@testable import TempleUI

/// Settings ▸ Hosts ▸ Add host…: the sheet's model, and the sheet rendered
/// in a window of its own, in process. No test reads the user's
/// `~/.ssh/config` or runs their ssh: both are stand-ins.
@MainActor
final class AddHostSheetTests: XCTestCase {
    private func hosts(records: [RemoteHostRecord] = [],
                       resolve: @escaping @Sendable (String) async -> ConnectionTest.Resolution = { _ in
                           .resolved(["user": "mentes", "hostname": "10.0.0.2"])
                       },
                       configReads: @escaping () -> [SSHConfigHost]) -> RemoteHostsModel {
        let defaults = Fixture.uniqueDefaults()
        defaults.set(RemoteHostList(records: records).encode(), forKey: RemoteHostsModel.hostsKey)
        return RemoteHostsModel(defaults: defaults, readConfigAliases: configReads, resolveAlias: resolve)
    }

    private func numbered(_ count: Int) -> [SSHConfigHost] {
        (1...count).map { SSHConfigHost(alias: "host-\($0)") }
    }

    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { spin(0.05) }
    }

    /// The config is read as the sheet opens (an alias added since the
    /// card appeared is offered), not before; only aliases not in use are
    /// offered, a hand-added host with an alias's name taking it out too.
    func testTheConfigIsReadAsTheSheetOpensAndOnlyUnusedAliasesAreOffered() {
        var reads = 0
        let records: [RemoteHostRecord] = [.config("box"), RemoteHostRecord(name: "jetson", source: .temple, address: "a")]
        let model = hosts(records: records) { reads += 1; return ["box", "jetson", "spare"] }
        XCTAssertEqual(reads, 0)
        let sheet = AddHostSheetModel(hosts: model)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(sheet.offered.map(\.alias), ["spare"])
        XCTAssertNil(sheet.emptyNote)
        sheet.dismissed()
    }

    /// Aliases that say how to log in first, bare names (no login, going
    /// where the name says, like github.com) last, the rest between, the
    /// config's order within each. Nothing is hidden.
    func testLoginAliasesRankFirstAndBareNamesLast() {
        let hosts: [SSHConfigHost] = [
            "github.com",
            SSHConfigHost(alias: "build", options: ["hostname": "10.0.0.9"]),
            SSHConfigHost(alias: "jetson-mentes", options: ["user": "mentes"]),
            SSHConfigHost(alias: "gitlab.com", options: ["hostname": "GitLab.com"]),
            SSHConfigHost(alias: "keyed", options: ["identityfile": "~/.ssh/k"]),
            SSHConfigHost(alias: "relay", options: ["proxyjump": "gate"]),
        ]
        XCTAssertEqual(AddHostSheetModel.ranked(hosts).map(\.alias),
                       ["jetson-mentes", "keyed", "build", "github.com", "gitlab.com", "relay"],
                       "the rule is login set first, the name going where it says last; nothing else counts")
    }

    /// The field filters live, ignoring case: aliases it starts first, then
    /// those it is inside of; cleared, every alias again.
    func testTheFieldFiltersAsItIsTyped() {
        let sheet = AddHostSheetModel(hosts: hosts { ["masterblaster-mentes", "jetson-mentes", "Mentes-box", "github.com"] })
        sheet.text = "ment"
        XCTAssertEqual(sheet.shown.map(\.alias), ["Mentes-box", "masterblaster-mentes", "jetson-mentes"])
        sheet.text = "  JET "
        XCTAssertEqual(sheet.shown.map(\.alias), ["jetson-mentes"])
        sheet.text = "nothing-like-it"
        XCTAssertEqual(sheet.shown.map(\.alias), [])
        XCTAssertNil(sheet.showAllCount)
        sheet.text = ""
        XCTAssertEqual(sheet.shown.count, 4)
        sheet.dismissed()
    }

    /// Unfiltered, the first six and "Show all N…", which shows every one
    /// (the sheet grows; there is no scroll view). A filter with more than
    /// six matches is cut the same way.
    func testSixAreShownThenShowAll() {
        let sheet = AddHostSheetModel(hosts: hosts { self.numbered(9) })
        XCTAssertEqual(sheet.shown.map(\.alias), (1...6).map { "host-\($0)" })
        XCTAssertEqual(sheet.showAllCount, 9)
        XCTAssertEqual(RemoteCopy.addHostShowAll(9), "Show all 9\u{2026}")
        sheet.text = "host-1"
        XCTAssertNil(sheet.showAllCount, "one match: nothing more to show")
        sheet.text = "host"
        XCTAssertEqual(sheet.showAllCount, 9)
        sheet.text = ""
        sheet.showAll()
        XCTAssertEqual(sheet.shown.count, 9)
        XCTAssertNil(sheet.showAllCount)
        sheet.dismissed()
    }

    /// Clicking a row adds its alias at once and ends the sheet; it is in
    /// use, and the next sheet does not offer it. Turn off offers it again.
    func testARowAddsItsAliasAtOnce() {
        let model = hosts { ["box", "spare"] }
        let sheet = AddHostSheetModel(hosts: model)
        sheet.choose("spare")
        XCTAssertEqual(sheet.outcome, .added("spare"))
        XCTAssertEqual(model.records, [.config("spare")])
        XCTAssertEqual(sheet.pendingResolutions, 0, "an ended sheet resolves nothing more")
        XCTAssertEqual(AddHostSheetModel(hosts: model).offered.map(\.alias), ["box"])
        model.setConfigHost("spare", enabled: false)
        XCTAssertEqual(AddHostSheetModel(hosts: model).offered.map(\.alias), ["box", "spare"])
    }

    /// Return adds what the field holds: an offered alias turns on; a host
    /// already in use says so and the sheet stays; anything else opens the
    /// full form with it filled in. Add needs something in the field.
    func testReturnAddsWhatTheFieldHolds() {
        let model = hosts(records: [.config("box")]) { ["box", "spare"] }

        let empty = AddHostSheetModel(hosts: model)
        empty.text = "   "
        XCTAssertEqual(empty.trimmedText, "", "Add is disabled")
        empty.submit()
        XCTAssertNil(empty.outcome)
        empty.dismissed()

        let alias = AddHostSheetModel(hosts: model)
        alias.text = " spare "
        alias.submit()
        XCTAssertEqual(alias.outcome, .added("spare"))
        XCTAssertNotNil(model.record(named: "spare"))

        let inUse = AddHostSheetModel(hosts: model)
        inUse.text = "box"
        inUse.submit()
        XCTAssertNil(inUse.outcome, "the sheet stays")
        XCTAssertEqual(inUse.note, "box is already in use.")
        inUse.text = "box2"
        XCTAssertNil(inUse.note, "typing clears it")
        inUse.dismissed()

        let address = AddHostSheetModel(hosts: model)
        address.text = "sri@build-box.local:2222"
        address.submit()
        var expected = RemoteHostForm()
        expected.name = "build-box"; expected.address = "build-box.local"; expected.user = "sri"; expected.port = "2222"
        XCTAssertEqual(address.outcome, .details(expected))
        XCTAssertEqual(model.records.map(\.name), ["box", "spare"], "nothing is added until the form is saved")
    }

    /// The field's text as the form's fields: user, address, port, and a
    /// name from a host name's first label (none for an IP address).
    func testAnAddressIsReadIntoTheForm() {
        func fields(_ text: String) -> [String] {
            let form = AddHostSheetModel.form(for: text)
            return [form.name, form.user, form.address, form.port]
        }
        XCTAssertEqual(fields("10.0.0.2"), ["", "", "10.0.0.2", ""])
        XCTAssertEqual(fields("me@10.0.0.2"), ["", "me", "10.0.0.2", ""])
        XCTAssertEqual(fields("box.lan"), ["box", "", "box.lan", ""])
        XCTAssertEqual(fields("me@[fe80::1]:2200"), ["", "me", "fe80::1", "2200"])
        XCTAssertEqual(fields("fe80::1"), ["", "", "fe80::1", ""])
        // The form opens with exactly this; it is what the form shows.
        let request = HostFormRequest(editing: nil, prefill: AddHostSheetModel.form(for: "me@box.lan"))
        XCTAssertEqual(request.prefill?.user, "me")
    }

    /// Esc is Cancel: nothing is added, nothing more is resolved, and an
    /// ended sheet ends once. Enter details… opens an empty form, Edit
    /// ~/.ssh/config the file.
    func testCancelAddsNothing() {
        let model = hosts { ["box"] }
        let sheet = AddHostSheetModel(hosts: model)
        sheet.text = "box"
        sheet.cancel()
        XCTAssertEqual(sheet.outcome, .cancelled)
        XCTAssertEqual(model.records, [])
        XCTAssertEqual(sheet.pendingResolutions, 0)

        let details = AddHostSheetModel(hosts: model)
        details.enterDetails()
        XCTAssertEqual(details.outcome, .details(RemoteHostForm()))
        let edit = AddHostSheetModel(hosts: model)
        edit.editConfig()
        XCTAssertEqual(edit.outcome, .editConfig)
        XCTAssertEqual(RemoteCopy.addHostNotInConfig, "Not in ~/.ssh/config?")
        XCTAssertEqual(RemoteCopy.addHostEnterDetails, "Enter details\u{2026}")
        XCTAssertEqual(RemoteCopy.addHostEditConfig, "Edit ~/.ssh/config")
    }

    /// With no alias to offer the sheet says why, under the field: none in
    /// the config, or every one in use; it then resolves nothing.
    func testTheSheetSaysWhyNoAliasIsOffered() {
        let empty = AddHostSheetModel(hosts: hosts { [] })
        XCTAssertEqual(empty.emptyNote, "No hosts in ~/.ssh/config.")
        XCTAssertEqual(empty.shown, [])
        XCTAssertEqual(empty.pendingResolutions, 0)

        let all = AddHostSheetModel(hosts: hosts(records: [.config("box")]) { ["box"] })
        XCTAssertEqual(all.emptyNote, "Every host in ~/.ssh/config is in use.")
        XCTAssertEqual(all.pendingResolutions, 0)
    }

    /// `ssh -G` runs for the rows shown only, a few at once, once each; an
    /// alias it can't answer for is shown without a destination. Show all
    /// resolves the rest.
    func testOnlyTheRowsShownAreResolvedAFewAtATime() {
        let probe = ResolveProbe()
        let sheet = AddHostSheetModel(hosts: hosts(resolve: { await probe.resolve($0) }) { self.numbered(9) })
        waitUntil { sheet.destinations.count + sheet.unresolved.count >= 6 }
        XCTAssertEqual(sheet.destinations["host-1"], "mentes@host-1.lan")
        XCTAssertNil(sheet.destinations["host-3"], "ssh -G failed: no destination")
        XCTAssertTrue(sheet.unresolved.contains("host-3"))
        XCTAssertEqual(probe.asked.sorted(), (1...6).map { "host-\($0)" }, "only the rows shown")
        XCTAssertLessThanOrEqual(probe.peak, AddHostSheetModel.maxConcurrentResolutions)
        sheet.text = "host-1"
        sheet.text = ""
        spin()
        XCTAssertEqual(probe.asked.count, 6, "once each")

        sheet.showAll()
        waitUntil { sheet.destinations.count + sheet.unresolved.count >= 9 }
        XCTAssertEqual(probe.asked.count, 9)
        XCTAssertEqual(sheet.destinations["host-9"], "mentes@host-9.lan")
        sheet.dismissed()
    }

    /// `ssh -G`'s answer as the row shows it.
    func testTheDestinationIsUserAtHostname() {
        XCTAssertEqual(AddHostSheetModel.destination(["user": "mentes", "hostname": "10.0.0.4", "port": "22"]), "mentes@10.0.0.4")
        XCTAssertEqual(AddHostSheetModel.destination(["hostname": "box.lan"]), "box.lan")
        XCTAssertNil(AddHostSheetModel.destination(["user": "mentes"]))
    }

    /// Closing the sheet stops what `ssh -G` still runs, and nothing more starts.
    func testClosingTheSheetStopsItsResolutions() {
        let probe = ResolveProbe(delay: 30)
        let sheet = AddHostSheetModel(hosts: hosts(resolve: { await probe.resolve($0) }) { ["a", "b", "c", "d", "e"] })
        XCTAssertEqual(sheet.pendingResolutions, 5, "four running, one waiting")
        waitUntil { probe.asked.count == AddHostSheetModel.maxConcurrentResolutions }
        sheet.dismissed()
        XCTAssertEqual(sheet.pendingResolutions, 0)
        waitUntil { probe.cancelled == AddHostSheetModel.maxConcurrentResolutions }
        XCTAssertEqual(probe.cancelled, AddHostSheetModel.maxConcurrentResolutions, "each running ssh -G was cancelled")
        XCTAssertEqual(probe.asked.count, AddHostSheetModel.maxConcurrentResolutions, "the waiting one never started")
        XCTAssertEqual(sheet.destinations, [:])
    }

    /// The real resolver asks the user's ssh `-G` about the alias (local:
    /// it prints the configuration and connects nowhere), with nothing of
    /// Temple's added but what lets a helper run under any config.
    func testTheResolverAsksSSHForTheAliasWithoutConnecting() {
        XCTAssertEqual(RemoteHostComposition.aliasResolutionArgv("box", sshPath: "/usr/bin/ssh"),
                       ["/usr/bin/ssh", "-G", "-o", "ForkAfterAuthentication=no", "--", "box"])
    }

    /// The sheet renders each state: aliases with Show all, filtered,
    /// expanded, and an empty note.
    func testTheSheetRenders() {
        let sheet = AddHostSheetModel(hosts: hosts { self.numbered(8) })
        let window = render(AddHostSheet(sheet: sheet) { _ in }, size: NSSize(width: 520, height: 400))
        spin()
        sheet.text = "host-2"
        spin()
        sheet.text = ""
        sheet.showAll()
        spin()
        window.close()
        let emptyWindow = render(AddHostSheet(sheet: AddHostSheetModel(hosts: hosts { [] })) { _ in },
                                 size: NSSize(width: 520, height: 300))
        spin()
        emptyWindow.close()
        XCTAssertEqual(RemoteCopy.addHostTitle, "Add host")
        XCTAssertEqual(RemoteCopy.addHostFieldLabel, "Host")
        XCTAssertEqual(RemoteCopy.addHostPlaceholder, "alias from ~/.ssh/config, or user@address")
    }

    private func render<V: View>(_ view: V, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }
}

/// A stand-in `ssh -G`: answers after `delay`, fails for host-3, and counts
/// what it was asked, how many ran at once and how many were cancelled.
private final class ResolveProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private var running = 0
    private var _asked: [String] = []
    private var _peak = 0
    private var _cancelled = 0

    init(delay: TimeInterval = 0.05) { self.delay = delay }

    var asked: [String] { lock.withLock { _asked } }
    var peak: Int { lock.withLock { _peak } }
    var cancelled: Int { lock.withLock { _cancelled } }

    func resolve(_ alias: String) async -> ConnectionTest.Resolution {
        lock.withLock {
            _asked.append(alias)
            running += 1
            _peak = max(_peak, running)
        }
        do {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        } catch {
            lock.withLock { _cancelled += 1; running -= 1 }
            return .failed("cancelled")
        }
        lock.withLock { running -= 1 }
        return alias == "host-3" ? .failed("no such host") : .resolved(["user": "mentes", "hostname": "\(alias).lan"])
    }
}
