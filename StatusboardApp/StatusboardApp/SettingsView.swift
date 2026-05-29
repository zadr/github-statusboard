import SwiftUI

/// Traditional macOS Settings window: a `TabView` of `Form`s. We do not set a
/// fixed frame — SwiftUI sizes each tab to fit its `Form`, and the system
/// supplies the standard preferences chrome (tab bar, padding, divider).
struct SettingsView: View {
    @Bindable var model: PRDashboardModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            FiltersSettings(model: model)
                .tabItem { Label("Filters", systemImage: "line.3.horizontal.decrease.circle") }
            UsersSettings(model: model)
                .tabItem { Label("Users", systemImage: "person.2") }
        }
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Bindable var model: PRDashboardModel

    var body: some View {
        Form {
            Picker("Refresh every:", selection: $model.refreshInterval) {
                Text("1 minute").tag(TimeInterval(60))
                Text("5 minutes").tag(TimeInterval(300))
                Text("15 minutes").tag(TimeInterval(900))
                Text("30 minutes").tag(TimeInterval(1800))
                Text("1 hour").tag(TimeInterval(3600))
            }

            Section {
                Text("Statusboard talks to GitHub via the `gh` CLI. Install it and run `gh auth login` to authenticate.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct FiltersSettings: View {
    @Bindable var model: PRDashboardModel

    var body: some View {
        Form {
            Section("Orgs") {
                StringListField(label: "Include", values: Binding(
                    get: { model.filter.includeOrgs },
                    set: { model.filter.includeOrgs = $0 }
                ))
                StringListField(label: "Exclude", values: Binding(
                    get: { model.filter.excludeOrgs },
                    set: { model.filter.excludeOrgs = $0 }
                ))
            }
            Section("Repos") {
                StringListField(label: "Include", values: Binding(
                    get: { model.filter.includeRepos },
                    set: { model.filter.includeRepos = $0 }
                ))
                StringListField(label: "Exclude", values: Binding(
                    get: { model.filter.excludeRepos },
                    set: { model.filter.excludeRepos = $0 }
                ))
            }
            Section {
                Text("Globs supported: `*`, `?`, `[abc]`. Matching is case-insensitive. One pattern per line.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct UsersSettings: View {
    @Bindable var model: PRDashboardModel

    var body: some View {
        Form {
            Section("Monitor users") {
                StringListField(label: "Logins", values: $model.monitorUsers)
            }
            Section {
                Text("Leave empty to track the authenticated user (`@me`). One login per line.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct StringListField: View {
    let label: String
    @Binding var values: [String]

    var body: some View {
        let textBinding = Binding<String>(
            get: { values.joined(separator: "\n") },
            set: { newValue in
                values = newValue
                    .split(whereSeparator: { $0.isNewline })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
        LabeledContent(label) {
            TextEditor(text: textBinding)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 60)
        }
    }
}
