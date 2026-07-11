import SwiftUI

/// Temple's mark: a gate (pediment + two pillars) with a terminal prompt lit in
/// the doorway — the same shape as the app icon (Scripts/make-icon.sh).
struct TempleMark: View {
    var size: CGFloat = 40
    /// The gate itself; the prompt inside always reads as the "lit" element.
    var tint: Color = .secondary

    var body: some View {
        Canvas { context, canvasSize in
            let u = canvasSize.width / 512
            let cx = canvasSize.width / 2
            let flip = { (y: CGFloat) in canvasSize.height - y * u }   // design space is y-up

            var gate = Path()
            gate.move(to: CGPoint(x: cx - 165 * u, y: flip(330)))       // pediment
            gate.addLine(to: CGPoint(x: cx, y: flip(430)))
            gate.addLine(to: CGPoint(x: cx + 165 * u, y: flip(430 - 100)))
            gate.closeSubpath()
            gate.addRoundedRect(in: CGRect(x: cx - 150 * u, y: flip(326),
                                           width: 300 * u, height: 30 * u),
                                cornerSize: CGSize(width: 4 * u, height: 4 * u))
            for x in [cx - 140 * u, cx + 94 * u] {                      // pillars
                gate.addRect(CGRect(x: x, y: flip(292), width: 46 * u, height: 162 * u))
            }
            gate.addRoundedRect(in: CGRect(x: cx - 168 * u, y: flip(126),
                                           width: 336 * u, height: 26 * u),
                                cornerSize: CGSize(width: 4 * u, height: 4 * u))
            context.fill(gate, with: .color(tint))

            let px = cx - 8 * u, py = flip(208)                          // prompt
            var caret = Path()
            caret.move(to: CGPoint(x: px - 28 * u, y: py - 28 * u))
            caret.addLine(to: CGPoint(x: px + 10 * u, y: py))
            caret.addLine(to: CGPoint(x: px - 28 * u, y: py + 28 * u))
            context.stroke(caret, with: .color(.primary),
                           style: StrokeStyle(lineWidth: 20 * u, lineCap: .round, lineJoin: .round))
            context.fill(
                Path(roundedRect: CGRect(x: px + 26 * u, y: py + 22 * u,
                                         width: 44 * u, height: 16 * u),
                     cornerRadius: 8 * u),
                with: .color(.primary))
        }
        .frame(width: size, height: size * 0.86)
        .accessibilityLabel("Temple")
    }
}
