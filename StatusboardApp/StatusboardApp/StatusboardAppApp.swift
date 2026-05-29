import SwiftUI

@main
struct StatusboardAppApp: App {
    @State private var model = PRDashboardModel()

    init() {
        // Kick the refresh off in a detached Task so it can't block menu-bar
        // registration. The status item appears immediately; data fills in
        // asynchronously.
        let m = model
        Task { @MainActor in
            m.start()
        }
    }

    var body: some Scene {
        // The (title, systemImage) initializer is the simplest and most
        // reliable way to get an icon to render in the menu bar — the system
        // handles template-image setup and sizing for us.
        MenuBarExtra("Statusboard", systemImage: "checklist") {
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.menu)

        // Standard macOS Settings scene — opened from the menu, rendered with
        // the system preferences chrome.
        Settings {
            SettingsView(model: model)
        }
    }
}
