import SwiftUI

/// The find bar over a terminal (⌘F): the needle, the count, and the way
/// through the matches. Matching and highlighting are the terminal's own.
///
/// Return walks forward, ⇧Return back, Esc closes and returns the keyboard to
/// the terminal. ⌘G / ⌘⇧G work from the field or the terminal (KeyCatcher).
struct TerminalFindOverlay: View {
    @ObservedObject var find: TerminalFindModel

    var body: some View {
        if find.isPresented {
            TerminalFindBar(find: find)
                .padding(10)
        }
    }
}

private struct TerminalFindBar: View {
    @ObservedObject var find: TerminalFindModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        // Ghostty's proportions: a 180pt field with the count riding inside its
        // trailing end, then three bare glyph buttons. Compact enough to leave
        // most of the terminal's top line readable beneath it.
        HStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Find", text: $find.needle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 160)
                    .focused($fieldFocused)
            }
                .padding(.leading, 8)
                .padding(.trailing, 54)   // room for the count
                .padding(.vertical, 5)
                .background(Palette.controlFill, in: RoundedRectangle(cornerRadius: 6))
                .onSubmit {
                    // The field reports only the submit; the modifier is on the event.
                    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                        find.previous()
                    } else {
                        find.next()
                    }
                }
                .onExitCommand { find.close() }
                // An overlay, so the bar's size never depends on the count.
                .overlay(alignment: .trailing) {
                    if let count {
                        Text(count)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.trailing, 8)
                    }
                }
            control("chevron.up", help: "Previous match (⌘⇧G)") { find.previous() }
            control("chevron.down", help: "Next match (⌘G)") { find.next() }
            control("xmark", help: "Done (Esc)") { find.close() }
        }
        .padding(6)
        .background(Palette.panelBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        // The bar is rebuilt with every tab switch, so the keyboard is claimed
        // only when the model asked for it (open / ⌘F), never on a plain rebuild.
        .onAppear(perform: claimFocusIfRequested)
        .onChange(of: find.focusToken) { claimFocusIfRequested() }
    }

    /// "3/12" while there are matches — Ghostty's compact form, since it shares
    /// the field. Silent otherwise: an empty needle, no answer yet, or nothing
    /// found (the absence of highlights says that already).
    private var count: String? {
        guard !find.needle.isEmpty, let total = find.total, total > 0 else { return nil }
        if let selected = find.selected { return "\(selected + 1)/\(total)" }
        return "–/\(total)"
    }

    private func control(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func claimFocusIfRequested() {
        guard find.consumeFocusRequest() else { return }
        // The terminal holds the responder; SwiftUI focus won't take it away
        // on its own (see FieldFocus).
        FieldFocus.claim { fieldFocused = true }
    }
}
