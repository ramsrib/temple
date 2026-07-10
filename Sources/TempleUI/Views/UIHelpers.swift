import SwiftUI
import AppKit

enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    @MainActor
    static func string(from date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

/// A small colored activity dot (running / needs-attention). Hidden when idle.
struct ActivityDot: View {
    let state: ActivityState
    var size: CGFloat = 6
    var body: some View {
        Circle()
            .fill(state.dotColor)
            .frame(width: size, height: size)
            .opacity(state.showsDot ? 1 : 0)
    }
}
