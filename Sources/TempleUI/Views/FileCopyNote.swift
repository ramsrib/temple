import SwiftUI

/// Files dropped or pasted onto a tab on a host: "Copying … to <host>…"
/// while they go, or why they didn't. Floats over the terminal's top-right
/// corner like the find bar, so the terminal keeps its size (a band would
/// resize the agent's screen twice for a copy that takes a second).
struct FileCopyNote: View {
    let status: FileCopyStatus
    let host: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch status.state {
            case .copying:
                ProgressView()
                    .controlSize(.small)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(RemoteCopy.copyingFiles(status.names, to: host))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420, alignment: .leading)
            case .failed(let reason):
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(RemoteCopy.copyFailed(status.names.first ?? "", of: status.total, to: host))
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: 360, alignment: .leading)
                Button(RemoteCopy.copyFailedDismiss, action: dismiss)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Palette.panelBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .frame(maxWidth: 520, alignment: .trailing)
        .padding(10)
    }
}
