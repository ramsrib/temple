import SwiftUI
import AppKit
import TempleCore

/// The empty-state / ⌘N launcher (ADR-008/012, U4): pick an agent + a project
/// (indexed, or Choose folder… for an un-indexed dir). Spawn-terminal MVP — no
/// prompt input; submitting opens the terminal fresh.
struct LauncherView: View {
    @EnvironmentObject var model: AppModel
    /// `true` when shown as a modal sheet (⌘N / + New session), `false` inline.
    let isSheet: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var agent: Agent = .claude
    @State private var projectPath: String?

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text("Start a session")
                    .font(.system(size: 20, weight: .semibold))
                Text("Launch a fresh agent in a project directory.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                agentSelector
                projectPicker
            }
            .frame(maxWidth: 420)

            HStack(spacing: 10) {
                if isSheet {
                    Button("Cancel") { close() }
                        .keyboardShortcut(.cancelAction)
                }
                Button(action: start) {
                    Text("Start \(agent.displayName)")
                        .frame(minWidth: 120)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(projectPath == nil)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            agent = model.settings.defaultAgent
            if projectPath == nil { projectPath = model.launcherDefaultProject }
        }
    }

    private var agentSelector: some View {
        Picker("Agent", selection: $agent) {
            ForEach(Agent.allCases, id: \.self) { a in
                Text(a.displayName).tag(a)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var projectPicker: some View {
        HStack {
            Text("Project")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(model.index.projects) { project in
                    Button(project.name) { projectPath = project.path }
                }
                Divider()
                Button("Choose folder…") { chooseFolder() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(projectLabel)
                        .lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var projectLabel: String {
        guard let projectPath else { return "Choose…" }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            projectPath = url.path
        }
    }

    private func start() {
        guard let projectPath else { return }
        model.openSessions.newSession(agent: agent, projectPath: projectPath)
        close()
    }

    private func close() {
        model.launcherPresented = false
        if isSheet { dismiss() }
    }
}
