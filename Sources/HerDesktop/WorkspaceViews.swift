import SwiftUI

struct CenterWorkspaceView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Group {
            switch model.selectedSection {
            case .today:
                ConversationView()
            case .memory:
                MemoryWorkspaceView()
            case .projects:
                ProjectsWorkspaceView()
            case .apps:
                WebAppsWorkspaceView()
            case .tools:
                ToolsWorkspaceView()
            case .agents:
                AgentsWorkspaceView()
            case .characters:
                CharactersWorkspaceView()
            case .worldBooks:
                WorldBooksWorkspaceView()
            }
        }
    }
}
