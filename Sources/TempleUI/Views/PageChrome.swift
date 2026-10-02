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

    /// Where the page column starts in a page `width` wide: the inset, plus
    /// half of whatever the page is wider than the cap.
    static func columnLeading(pageWidth width: CGFloat, inset: CGFloat = gutter) -> CGFloat {
        inset + max(0, (width - pageWidth) / 2)
    }

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

extension View {
    /// The page column — capped at `PageChrome.pageWidth`, centred beyond it —
    /// placed from the *page's* width (`measuringPageWidth`), not from the
    /// width this view is offered. Inside a scroll view that offer is short by
    /// the scroller, so a column centred in it sat a few points left of one
    /// outside it: Settings' title (in its scroll view) was ~8pt left of
    /// History's (above its list). Every page column goes through here, so
    /// titles, rows and bars share one leading edge whatever scrolls.
    func pageColumn(pageWidth width: CGFloat, inset: CGFloat = PageChrome.gutter) -> some View {
        frame(maxWidth: PageChrome.pageWidth - 2 * inset, alignment: .leading)
            .padding(.leading, PageChrome.columnLeading(pageWidth: width, inset: inset))
            .padding(.trailing, inset)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Reports the page's width into `width`, for `pageColumn`. A background
    /// reader, so it adds no layout of its own.
    func measuringPageWidth(_ width: Binding<CGFloat>) -> some View {
        background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { width.wrappedValue = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in width.wrappedValue = new }
            })
    }
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

/// The pages' segmented control, in the toolbar's flat vocabulary: a 28pt
/// `controlFill` track, the selected segment filled with the accent. The native
/// `.segmented` picker was the one bezeled control on a flat row, 22pt beside
/// 28pt menus, and in dark it inverted: the bright track read as the
/// selection and the selected knob as a hole.
struct FlatSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var width: CGFloat? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(label(option))
                        .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .foregroundStyle(selected ? (colorScheme == .dark ? Color.black : Color.white) : Color.secondary)
                        .background(selected ? Palette.accent : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(width: width, height: 28)
        .background(Palette.controlFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
