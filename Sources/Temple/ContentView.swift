import SwiftUI
import AppKit
import TempleCore
import TempleTerminalAPI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let session = model.selectedSession {
                SessionDetailView(session: session)
                    .id(session.id)  // fresh surface per session
            } else {
                ContentUnavailableViewCompat(
                    "Select a session",
                    systemImage: "terminal",
                    description: "Pick a project session to open its terminal.")
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            if model.isLoading {
                Label("Loading sessions…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.index.projects) { project in
                Section(project.name) {
                    ForEach(project.sessions) { session in
                        SessionRow(session: session).tag(session.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Temple")
    }
}

struct SessionRow: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.agent == .claude ? Color.orange : Color.purple)
                .frame(width: 7, height: 7)
            Text(session.title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

// MARK: - Detail

struct SessionDetailView: View {
    @EnvironmentObject var model: AppModel
    let session: AgentSession

    @State private var surface: TerminalSurface?

    private var resumeCommand: String {
        session.resume.argv.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.title2).bold().lineLimit(2)
                Text("\(session.agent.displayName)  ·  \(session.projectPath)")
                    .font(.callout).foregroundStyle(.secondary)
            }

            terminalPane
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Button {
                    copyToPasteboard(resumeCommand)
                } label: {
                    Label("Copy resume command", systemImage: "doc.on.doc")
                }
                Spacer()
                Text("cwd: \(session.projectPath)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var terminalPane: some View {
        if let surface {
            TerminalSurfaceHost(surface: surface, command: TerminalCommand(resuming: session))
                .id(session.id)
        } else {
            Color.clear.onAppear {
                surface = model.surfaceFactory.makeSurface(appearance: .default)
            }
        }
    }
}

// MARK: - Small compat shims

private func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// `ContentUnavailableView` is macOS 14+, but keep a trivial fallback for clarity.
struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    let description: String
    init(_ title: String, systemImage: String, description: String) {
        self.title = title; self.systemImage = systemImage; self.description = description
    }
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title3)
            Text(description).foregroundStyle(.secondary)
        }
    }
}
