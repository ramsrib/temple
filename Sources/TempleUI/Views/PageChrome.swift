import SwiftUI

/// The header shared by the page-style tabs (History, Settings): a 24pt title,
/// a 12pt subtitle that states the page's inventory, and a trailing line
/// ("Updated 2 min ago · Refresh", "Checked just now · Check again").
///
/// One component so the title sits at the same place on both tabs and does
/// not jump when switching between them.
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: Text
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                subtitle
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

enum PageChrome {
    /// The page column caps at this width and centres beyond it.
    static let pageWidth: CGFloat = 1100
    static let gutter: CGFloat = 28
    /// Space above the title.
    static let top: CGFloat = 36

    /// "just now" under a minute, then "2 min. ago" — the trailing line's clock.
    static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

/// An uppercase, letter-spaced section label trailed by a hairline rule — the
/// launcher's and Settings' section header. An optional leading view (an
/// `AgentBadge`) sits before the label.
struct SectionRule<Leading: View>: View {
    let title: String
    let leading: Leading

    init(_ title: String) where Leading == EmptyView {
        self.title = title
        self.leading = EmptyView()
    }

    init(_ title: String, @ViewBuilder leading: () -> Leading) {
        self.title = title
        self.leading = leading()
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                leading
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
            }
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)
        }
        .padding(.bottom, 8)
    }
}
