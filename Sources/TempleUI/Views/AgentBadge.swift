import SwiftUI
import AppKit
import TempleCore

/// Loads + caches the bundled brand marks (`Resources/claude.svg`,
/// `codex.svg`). Codex's OpenAI mark is monochrome → rendered as a template so
/// it tints to the foreground; Claude keeps its brand terracotta.
enum AgentIcon {
    private static var cache: [Agent: NSImage] = [:]

    @MainActor
    static func image(for agent: Agent) -> NSImage? {
        if let cached = cache[agent] { return cached }
        let name = (agent == .claude) ? "claude" : "codex"
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = (agent == .codex)
        cache[agent] = image
        return image
    }
}

/// Per-session agent badge (sidebar rows + tab chips), rendered at row size.
struct AgentBadge: View {
    let agent: Agent
    var size: CGFloat = 13

    var body: some View {
        if let image = AgentIcon.image(for: agent) {
            if agent == .codex {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .foregroundStyle(.primary)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            }
        } else {
            // Fallback if SVG rendering is unavailable.
            Circle()
                .fill(agent == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color.primary)
                .frame(width: size * 0.55, height: size * 0.55)
        }
    }
}

extension AgentIcon {
    private static var menuCache: [Agent: NSImage] = [:]

    /// Menu-item sized copy of the mark. `NSMenu` draws an item's image at the
    /// `NSImage`'s own `size` and ignores the SwiftUI frame modifiers that
    /// `AgentBadge` relies on, and the bundled marks arrive at their 24pt
    /// viewBox — a head taller than the menu's text.
    ///
    /// One size, cached by agent alone: a `side` parameter over a cache keyed
    /// without it would hand the second caller the first one's size.
    @MainActor
    static func menuImage(for agent: Agent) -> NSImage? {
        if let cached = menuCache[agent] { return cached }
        guard let copy = image(for: agent)?.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 14, height: 14)
        copy.isTemplate = (agent == .codex)
        menuCache[agent] = copy
        return copy
    }
}
