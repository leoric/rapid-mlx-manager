import SwiftUI

@main
struct RapidManagerApp: App {
    @StateObject private var controller = ServerController()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(controller)
        } label: {
            Image(systemName: icon)
        }
        .menuBarExtraStyle(.window)
    }

    private var icon: String {
        switch controller.status {
        case .running, .external: return "bolt.circle.fill"
        case .starting, .stopping: return "arrow.triangle.2.circlepath.circle"
        case .failed: return "exclamationmark.triangle"
        case .stopped: return "bolt.circle"
        }
    }
}
