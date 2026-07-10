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
