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

/// The page's last measured width, kept past the page views that measured it.
///
/// A page's width is view state, so every History or Settings view starts
/// without one. Seeded with a guess (1000), a window wider than the cap drew
/// the page's first frame with the column at the guess's offset, then moved
/// it. Every page fills the same detail pane, so the width the last page
/// measured is the next one's starting point: right, or corrected within a
/// frame after a resize while no page was open.
@MainActor
enum PageWidthMemory {
    static var last: CGFloat?
}

extension View {
    /// The page column — capped at `PageChrome.pageWidth`, centred beyond it —
    /// placed from the *page's* width (`measuringPageWidth`), not from the
    /// width this view is offered. Inside a scroll view that offer is short by
    /// the scroller, so a column centred in it sat a few points left of one
    /// outside it: Settings' title (in its scroll view) was ~8pt left of
    /// History's (above its list). Every page column goes through here, so
    /// titles, rows and bars share one leading edge whatever scrolls.
    ///
    /// Before any page has been measured (`nil`: the first page of a launch)
    /// the column is laid out but not drawn, so it is never seen at a guessed
    /// offset and then moving.
    func pageColumn(pageWidth width: CGFloat?, inset: CGFloat = PageChrome.gutter) -> some View {
        frame(maxWidth: PageChrome.pageWidth - 2 * inset, alignment: .leading)
            .padding(.leading, PageChrome.columnLeading(pageWidth: width ?? 0, inset: inset))
            .padding(.trailing, inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(width == nil ? 0 : 1)
    }

    /// Reports the page's width into `width`, for `pageColumn`, and remembers
    /// it for the next page (`PageWidthMemory`). A background reader, so it
    /// adds no layout of its own.
    func measuringPageWidth(_ width: Binding<CGFloat?>) -> some View {
        background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { recordPageWidth(geo.size.width, into: width) }
                    .onChange(of: geo.size.width) { _, new in recordPageWidth(new, into: width) }
            })
    }
}

@MainActor
private func recordPageWidth(_ measured: CGFloat, into width: Binding<CGFloat?>) {
    PageWidthMemory.last = measured
    if width.wrappedValue != measured { width.wrappedValue = measured }
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
///
/// To VoiceOver and Full Keyboard Access it is that native picker all the
/// same (`accessibilityRepresentation`): one control named `label`, its
/// segments stepped with the arrow keys, rather than a row of unnamed buttons.
struct FlatSegmentedPicker<Value: Hashable>: View {
    /// The control's accessible name: the row label it sits beside.
    let label: String
    @Binding var selection: Value
    let options: [Value]
    let optionTitle: (Value) -> String
    var width: CGFloat? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { Self.select(option, in: $selection) } label: {
                    Text(optionTitle(option))
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
            }
        }
        .padding(2)
        .frame(width: width, height: 28)
        .background(Palette.controlFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityRepresentation {
            Picker(label, selection: Binding(get: { selection },
                                             set: { Self.select($0, in: $selection) })) {
                ForEach(options, id: \.self) { option in
                    Text(optionTitle(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    /// Choose `option`, if it is a change. Clicking the segment that is
    /// already selected must write nothing: behind Settings' pickers is a
    /// settings key, and re-writing the value it already reads would persist
    /// a default ("system", "claude") the user never chose.
    static func select(_ option: Value, in selection: Binding<Value>) {
        guard option != selection.wrappedValue else { return }
        selection.wrappedValue = option
    }
}
