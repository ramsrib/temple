import SwiftUI
import TempleCore

/// A project named the way every surface names it: the folder's name, then the
/// machine as its own quieter label, `@host`, the sidebar heading's tag.
///
/// Never one string. `ProjectKey.displayName` ("mentes-ai @mac-mini-personal")
/// is for sentences; a label that truncated it from the middle showed
/// "mentes…ersonal", losing which project AND which machine. Here the two
/// truncate separately, and the machine gives way first. This Mac is never
/// named, so a setup with no hosts looks as it always did.
struct ProjectNameLabel: View {
    let key: ProjectKey
    var font: Font = .system(size: 13)
    var hostFont: Font = .system(size: 11)
    /// The name's own style (selection weight, colour) is the caller's.
    var nameStyle: AnyShapeStyle = AnyShapeStyle(.primary)
    var axis: Axis = .horizontal

    /// The machine's tag, or nil on this Mac.
    static func hostTag(_ key: ProjectKey) -> String? {
        key.host.isLocal ? nil : "@" + key.host.rawValue
    }

    var body: some View {
        switch axis {
        case .horizontal:
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                name
                host
            }
        case .vertical:
            VStack(spacing: 1) {
                name
                host
            }
        }
    }

    private var name: some View {
        Text(key.name)
            .font(font)
            .foregroundStyle(nameStyle)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    @ViewBuilder
    private var host: some View {
        if let tag = Self.hostTag(key) {
            // From the middle, so "-mentes" and "-personal" survive.
            Text(tag)
                .font(hostFont)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
        }
    }
}
