import AppKit
import SwiftUI
import XCTest
import TempleCore
@testable import TempleUI

/// A host project's heading line laid out in process at the sidebar's
/// widths: the rule gives way first, then the host, the name last. The
/// computer-use pass on 99eb8e8 saw "TEMPLE-UX5 …" at the default width,
/// the host given nothing while the rule had room.
@MainActor
final class ProjectHeadingLayoutTests: XCTestCase {
    /// What a heading line gets of the sidebar: the list's 6 a side and the
    /// header's 4 a side (`SidebarView`, `ProjectDisclosure.header`).
    private static let sideInsets: CGFloat = 20
    private static let defaultSidebar: CGFloat = 280
    private static let minimumSidebar: CGFloat = 240

    private let title = ProjectHeaderTitle(ProjectKey(host: HostID(rawValue: "masterblaster-mentes"), path: "/tmp/temple-ux5"))

    private func layOut(sidebar: CGFloat, hovering: Bool = false) -> (name: CGFloat, host: CGFloat?) {
        var result: (CGFloat, CGFloat?)?
        let line = ProjectHeadingLine(title: title, expanded: true, hovering: hovering) { result = ($0, $1) }
            .frame(width: sidebar - Self.sideInsets)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: sidebar, height: 60), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: line)
        window.contentView?.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        while result?.1 == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        window.close()
        return result ?? (0, nil)
    }

    /// The width a text wants on one line, set as the heading sets it.
    private func ideal<V: View>(_ text: V) -> CGFloat {
        NSHostingView(rootView: text.lineLimit(1)).fittingSize.width
    }

    private var nameIdeal: CGFloat {
        ideal(Text(title.name).font(.system(size: 11, weight: .medium)).tracking(1.4))
    }

    private var hostIdeal: CGFloat {
        ideal(Text(title.hostLabel ?? "").font(.system(size: 11)))
    }

    func testTheWholeHostFitsAtTheDefaultSidebarWidth() throws {
        XCTAssertEqual(title.hostLabel, "@masterblaster-mentes")
        let laid = layOut(sidebar: Self.defaultSidebar)
        let host = try XCTUnwrap(laid.host, "the host was laid out")
        XCTAssertGreaterThanOrEqual(host, hostIdeal - 0.5, "the whole @masterblaster-mentes, the rule giving way first")
        XCTAssertGreaterThanOrEqual(laid.name, nameIdeal - 0.5, "the name whole")
    }

    func testTheNameStaysWholeAtTheMinimumSidebarWidth() throws {
        for hovering in [false, true] {
            let laid = layOut(sidebar: Self.minimumSidebar, hovering: hovering)
            XCTAssertGreaterThanOrEqual(laid.name, nameIdeal - 0.5, "the name whole, hovering \(hovering)")
            let host = try XCTUnwrap(laid.host)
            XCTAssertGreaterThan(host, 30, "the host truncates in the middle, it does not vanish (hovering \(hovering))")
        }
    }
}
