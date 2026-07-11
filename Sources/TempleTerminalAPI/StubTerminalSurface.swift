import AppKit

/// A placeholder `TerminalSurface`: renders the spawned command + cwd and walks
/// a manual state machine. Stands in for libghostty until Track T fuses.
@MainActor
public final class StubTerminalSurface: TerminalSurface {
    public var view: NSView { stubView }
    public weak var delegate: TerminalSurfaceDelegate?

    public private(set) var processState: TerminalProcessState = .notStarted {
        didSet {
            guard processState != oldValue else { return }
            delegate?.surface(self, didChangeState: processState)
        }
    }

    private let stubView: StubTerminalView

    public init(appearance: TerminalAppearance = .default) {
        stubView = StubTerminalView(appearance: appearance)
    }

    public func start(_ command: TerminalCommand) throws {
        stubView.render(command: command, state: "running (stub)")
        processState = .running(pid: 0)
    }

    public func focus() {
        stubView.window?.makeFirstResponder(stubView)
    }

    public func apply(_ appearance: TerminalAppearance) {
        stubView.apply(appearance)
    }

    public func requestGracefulExit() {
        exitNow(status: 0)
    }

    public func terminate() {
        exitNow(status: 9)
    }

    // MARK: Manual state machine (drive from dev UI or tests)

    public func simulateExit(status: Int32) { exitNow(status: status) }
    public func simulateBell() { delegate?.surfaceDidRing(self) }
    public func simulateNotification(title: String, body: String) {
        delegate?.surface(self, didPostNotification: title, body: body)
    }
    public func simulateTitle(_ title: String) {
        delegate?.surface(self, didUpdateTitle: title)
    }
    public func simulateSubmitInput() {
        delegate?.surfaceDidSubmitInput(self)
    }

    private func exitNow(status: Int32) {
        guard case .running = processState else { return }
        stubView.setState("exited (\(status))")
        processState = .exited(status: status)
    }
}

public struct StubTerminalSurfaceFactory: TerminalSurfaceFactory {
    public nonisolated init() {}
    public func makeSurface(appearance: TerminalAppearance) -> TerminalSurface {
        StubTerminalSurface(appearance: appearance)
    }
}

// MARK: - View

final class StubTerminalView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private var terminalAppearance: TerminalAppearance
    private var command: TerminalCommand?
    private var stateText = "not started"

    init(appearance: TerminalAppearance) {
        self.terminalAppearance = appearance
        super.init(frame: .zero)
        wantsLayer = true
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 16),
        ])
        applyColors()
        refreshText()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    func render(command: TerminalCommand, state: String) {
        self.command = command
        stateText = state
        refreshText()
    }

    func setState(_ state: String) {
        stateText = state
        refreshText()
    }

    func apply(_ appearance: TerminalAppearance) {
        self.terminalAppearance = appearance
        applyColors()
        refreshText()
    }

    private func applyColors() {
        layer?.backgroundColor = terminalAppearance.colorScheme == .dark
            ? NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
            : NSColor(calibratedWhite: 0.96, alpha: 1).cgColor
        label.textColor = terminalAppearance.colorScheme == .dark ? .green : NSColor(calibratedRed: 0, green: 0.4, blue: 0, alpha: 1)
    }

    private func refreshText() {
        let font = NSFont.monospacedSystemFont(ofSize: terminalAppearance.fontSize, weight: .regular)
        label.font = font
        var lines = ["[stub terminal — \(stateText)]"]
        if let command {
            lines.append("cwd: \(command.cwd)")
            lines.append("$ " + command.argv.joined(separator: " "))
        }
        label.stringValue = lines.joined(separator: "\n")
    }
}
