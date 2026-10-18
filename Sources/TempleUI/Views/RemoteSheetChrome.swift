import SwiftUI

// One chrome for every remote sheet (Add host, the host form, the folder
// sheet, Running sessions; docs/designs/remote-ssh.md, "Cold-read round"):
// 20pt padding, a fixed width, a leading VStack 12pt apart; a 15pt title
// with the host after it in 12pt mono; a leading-aligned 96pt label column;
// Settings' field (28pt, control fill, radius 7, a graphite focus ring);
// hints 11 secondary under the field; problems in Settings' shape (a
// triangle and 11pt red). Layout rules as for the rest of the app's sheets
// (AGENTS.md): no `.fixedSize`, `Form` or `List`.

/// The remote sheets' measures.
enum RemoteSheetMetrics {
    /// Every remote sheet but Test connection (680, for its terminal).
    static let width: CGFloat = 520
    /// The label column of the host form and the Add host sheet alike.
    static let labelWidth: CGFloat = 96
}

/// A remote sheet's frame: padding, width and the stack.
struct RemoteSheetChrome<Content: View>: View {
    var width: CGFloat = RemoteSheetMetrics.width
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(20)
            .frame(width: width)
    }
}

/// The sheet's title, and the host it is about after it.
struct RemoteSheetTitle: View {
    let title: String
    var host: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            if let host {
                Text(host)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A labelled row: the 96pt leading label column (13 primary, level with
/// the field's text), then the control column.
struct RemoteFormRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .frame(width: RemoteSheetMetrics.labelWidth, alignment: .leading)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    /// Settings' field chrome (`SettingsView.textField`): 28pt high on the
    /// control fill, radius 7, and a graphite ring while focused.
    func templeFieldChrome(focused: Bool, leading: CGFloat = 9, trailing: CGFloat = 8) -> some View {
        padding(.leading, leading)
            .padding(.trailing, trailing)
            .frame(height: 28)
            .background(Palette.controlFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Palette.accent.opacity(0.5), lineWidth: 2)
                    .padding(-2)
                    .opacity(focused ? 1 : 0)
            }
    }
}

/// A hint under a field: 11 secondary.
struct RemoteHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What is wrong, in Settings' `problem` shape: a triangle and 11pt text,
/// red for a failure, orange for advice (and every "still running" line).
struct RemoteProblem: View {
    let text: String
    var color: Color = .red
    init(_ text: String, color: Color = .red) { self.text = text; self.color = color }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11))
        .foregroundStyle(color)
    }
}

/// A caption above a list under a field: 11 secondary.
struct RemoteListCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row of a list under a field: the whole row one plain button, washed
/// on hover (never the system's link colour).
struct RemoteListRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering ? Palette.hoverFill : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Links in a row that wraps to the next line when they don't fit, each
/// at its natural width: a label is never cut to fit its neighbours (the
/// Hosts card's links, where "Running sessions on <host>…" names the host
/// in full).
struct WrappingRow: Layout {
    var spacing: CGFloat = 14
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width ?? .infinity)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                                      anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            if !line.indices.isEmpty, needed > width {
                lines.append(line)
                line = Line()
            }
            line.width = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }
}
