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
    private func hosts(records: [RemoteHostRecord] = [], configReads: @escaping () -> [SSHConfigHost]) -> RemoteHostsModel {
        let defaults = Fixture.uniqueDefaults()
        defaults.set(RemoteHostList(records: records).encode(), forKey: RemoteHostsModel.hostsKey)
        return RemoteHostsModel(defaults: defaults, readConfigAliases: configReads)
    }

    private func numbered(_ count: Int) -> [SSHConfigHost] {
        (1...count).map { SSHConfigHost(alias: "host-\($0)") }
    }

    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
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
        XCTAssertNil(sheet.hiddenCount)
        sheet.text = ""
        XCTAssertEqual(sheet.shown.count, 4)
    }

    /// Unfiltered, the first six and "Show N more" (the number hidden, as
    /// the sidebar says it), which shows every one (the sheet grows; there
    /// is no scroll view). A filter with more than six matches is cut the
    /// same way.
    func testSixAreShownThenShowMore() {
        let sheet = AddHostSheetModel(hosts: hosts { self.numbered(9) })
        XCTAssertEqual(sheet.shown.map(\.alias), (1...6).map { "host-\($0)" })
        XCTAssertEqual(sheet.hiddenCount, 3)
        XCTAssertEqual(RemoteCopy.addHostShowMore(3), "Show 3 more")
        sheet.text = "host-1"
        XCTAssertNil(sheet.hiddenCount, "one match: nothing more to show")
        sheet.text = "host"
        XCTAssertEqual(sheet.hiddenCount, 3)
        sheet.text = ""
        sheet.showAll()
        XCTAssertEqual(sheet.shown.count, 9)
        XCTAssertNil(sheet.hiddenCount)
    }

    /// Clicking a row adds its alias at once and ends the sheet; it is in
    /// use, and the next sheet does not offer it. Turn off offers it again.
    func testARowAddsItsAliasAtOnce() {
        let model = hosts { ["box", "spare"] }
        let sheet = AddHostSheetModel(hosts: model)
        sheet.choose("spare")
        XCTAssertEqual(sheet.outcome, .added("spare"))
        XCTAssertEqual(model.records, [.config("spare")])
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

        let address = AddHostSheetModel(hosts: model)
        address.text = "sri@build-box.local:2222"
        address.submit()
        var expected = RemoteHostForm()
        expected.name = "build-box"; expected.address = "build-box.local"; expected.user = "sri"; expected.port = "2222"
        XCTAssertEqual(address.outcome, .details(expected))
        XCTAssertEqual(model.records.map(\.name), ["box", "spare"], "nothing is added until the form is saved")

        let unreadable = AddHostSheetModel(hosts: model)
        unreadable.text = "me@[fe80::1]garbage"
        unreadable.submit()
        XCTAssertNil(unreadable.outcome, "the sheet stays")
        XCTAssertEqual(unreadable.text, "me@[fe80::1]garbage", "the text stays to be corrected")
        XCTAssertEqual(unreadable.note, RemoteCopy.addHostUnreadable)
    }

    /// The list filters ignoring case, so Return does too: an exact alias
    /// first, else the one alias that matches ignoring case; two that do
    /// leave it to the form. A host in use is found the same way.
    func testReturnFindsAnAliasIgnoringCaseWhenOnlyOneMatches() {
        let model = hosts(records: [.config("Jetson")]) { ["box", "Mixed", "mixed", "Jetson"] }
        let upper = AddHostSheetModel(hosts: model)
        upper.text = "BOX"
        upper.submit()
        XCTAssertEqual(upper.outcome, .added("box"))

        let exact = AddHostSheetModel(hosts: model)
        exact.text = "mixed"
        exact.submit()
        XCTAssertEqual(exact.outcome, .added("mixed"), "the exact alias wins")

        let ambiguous = AddHostSheetModel(hosts: hosts { ["Mixed", "mixed"] })
        ambiguous.text = "MIXED"
        ambiguous.submit()
        XCTAssertEqual(ambiguous.outcome, .details(AddHostSheetModel.form(for: "MIXED")!), "two aliases match ignoring case: the form")

        let inUse = AddHostSheetModel(hosts: model)
        inUse.text = "jetson"
        inUse.submit()
        XCTAssertNil(inUse.outcome)
        XCTAssertEqual(inUse.note, "Jetson is already in use.")
    }

    /// The field's text as the form's fields: user, address, port, and a
    /// name from a host name's first label (none for an IP address). What
    /// can't be read as `user@address[:port]` is nil: a bracket must end the
    /// text or come right before a port.
    func testAnAddressIsReadIntoTheForm() {
        func fields(_ text: String) -> [String]? {
            AddHostSheetModel.form(for: text).map { [$0.name, $0.user, $0.address, $0.port] }
        }
        XCTAssertEqual(fields("10.0.0.2"), ["", "", "10.0.0.2", ""])
        XCTAssertEqual(fields("me@10.0.0.2"), ["", "me", "10.0.0.2", ""])
        XCTAssertEqual(fields("box.lan"), ["box", "", "box.lan", ""])
        XCTAssertEqual(fields("box.lan:2200"), ["box", "", "box.lan", "2200"])
        XCTAssertEqual(fields("me@[fe80::1]:2200"), ["", "me", "fe80::1", "2200"])
        XCTAssertEqual(fields("[fe80::1]"), ["", "", "fe80::1", ""])
        XCTAssertEqual(fields("fe80::1"), ["", "", "fe80::1", ""])
        for unreadable in ["me@[fe80::1]garbage", "[fe80::1]:", "[fe80::1]:22x", "[fe80::1", "fe80]", "box:", "box:ssh",
                           "@box", "me@", "a@b@c", "me@box lan", "[]"] {
            XCTAssertNil(AddHostSheetModel.form(for: unreadable), unreadable)
        }
        // The form opens with exactly this; it is what the form shows.
        let request = HostFormRequest(editing: nil, prefill: AddHostSheetModel.form(for: "me@box.lan"))
        XCTAssertEqual(request.prefill?.user, "me")
    }

    /// Esc is Cancel: nothing is added, and an ended sheet ends once.
    /// Enter details… opens an empty form, Edit ~/.ssh/config the file.
    func testCancelAddsNothing() {
        let model = hosts { ["box"] }
        let sheet = AddHostSheetModel(hosts: model)
        sheet.text = "box"
        sheet.cancel()
        XCTAssertEqual(sheet.outcome, .cancelled)
        XCTAssertEqual(model.records, [])

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
    /// the config, or every one in use.
    func testTheSheetSaysWhyNoAliasIsOffered() {
        let empty = AddHostSheetModel(hosts: hosts { [] })
        XCTAssertEqual(empty.emptyNote, "No hosts in ~/.ssh/config.")
        XCTAssertEqual(empty.shown, [])

        let all = AddHostSheetModel(hosts: hosts(records: [.config("box")]) { ["box"] })
        XCTAssertEqual(all.emptyNote, "Every host in ~/.ssh/config is in use.")
    }

    /// Opening the sheet runs nothing: no `ssh -G`, whose `Match exec`
    /// would run a config's commands for aliases nobody chose. Each row's
    /// `user@hostname` is what the alias's own blocks set.
    func testOpeningTheSheetRunsNothingAndShowsWhatTheConfigSets() {
        let launches = RemoteHostComposition.processLaunches
        let sheet = AddHostSheetModel(hosts: hosts {
            [SSHConfigHost(alias: "box", options: ["user": "mentes", "hostname": "10.0.0.4"]), "github.com"]
        })
        sheet.showAll()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(RemoteHostComposition.processLaunches, launches)
        XCTAssertEqual(sheet.shown.map(\.destination), ["mentes@10.0.0.4", nil])
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
        XCTAssertEqual(AddHostSheet.aliasColumn, 200, "a fixed column: the destinations don't move as rows change")
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
