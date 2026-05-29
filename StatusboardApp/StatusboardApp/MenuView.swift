import SwiftUI
import AppKit

/// Contents of the menu-bar dropdown, rendered as a traditional NSMenu via
/// `MenuBarExtra(.menu)`.
///
/// We keep the long list (`PRListView` + `ReviewListView`) in their own views
/// reading `model.state`, which is a single observable snapshot. Refresh-related
/// UI that flips frequently (`isRefreshing`, the refresh button) lives in a
/// separate view so toggling it doesn't invalidate the long list and force
/// AppKit to rebuild every menu item's backing text field.
struct MenuContent: View {
    let model: PRDashboardModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        StatusItem(model: model)

        Divider()

        PRListView(model: model)
        ReviewListView(model: model)
        EmptyStateRow(model: model)
        ErrorRow(model: model)

        Divider()

        RefreshButton(model: model)
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Statusboard") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

private struct StatusItem: View {
    let model: PRDashboardModel

    var body: some View {
        if let updated = model.state.lastUpdated {
            let stamp = updated.formatted(date: .omitted, time: .shortened)
            Text("Updated \(stamp)")
        } else if model.isRefreshing {
            Text("Loading…")
        } else {
            Text("Statusboard")
        }
    }
}

private struct RefreshButton: View {
    let model: PRDashboardModel

    var body: some View {
        Button(model.isRefreshing ? "Refreshing…" : "Refresh Now") {
            Task { await model.refresh() }
        }
        .keyboardShortcut("r")
        .disabled(model.isRefreshing)
    }
}

private struct EmptyStateRow: View {
    let model: PRDashboardModel

    var body: some View {
        if model.state.lastUpdated != nil && model.totalOpenItems == 0 {
            Text("Nothing open.")
        }
    }
}

private struct ErrorRow: View {
    let model: PRDashboardModel

    var body: some View {
        if let err = model.state.lastError {
            Divider()
            Text(err).foregroundStyle(.red)
        }
    }
}

private struct PRListView: View {
    let model: PRDashboardModel

    var body: some View {
        ForEach(model.grouped, id: \.0) { category, prs in
            if !prs.isEmpty {
                Section("\(category.label) (\(prs.count))") {
                    ForEach(prs) { pr in
                        PRMenuItem(pr: pr, model: model)
                    }
                }
            }
        }
    }
}

private struct ReviewListView: View {
    let model: PRDashboardModel

    var body: some View {
        let reviews = model.filteredReviews.sorted { ($0.repo, $0.number) < ($1.repo, $1.number) }
        if !reviews.isEmpty {
            Section("Awaiting Review (\(reviews.count))") {
                ForEach(reviews) { r in
                    // Plain button — clicking the row opens the PR in the
                    // browser. No submenu, since there are no review-only
                    // contextual actions yet.
                    Button("\(r.repo) #\(r.number) — @\(r.author) — \(r.title)") {
                        if let url = r.url { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
    }
}

/// One row per PR.
///
/// - PRs with a contextual action (Merge for approved-mergeable, Open for
///   Review for drafts) → `Menu` submenu containing just that action.
/// - Everything else → plain `Button` that opens the PR in the browser when
///   clicked.
private struct PRMenuItem: View {
    let pr: PullRequest
    let model: PRDashboardModel

    var body: some View {
        if pr.isApprovedAndMergeable {
            Menu("\(pr.repo) #\(pr.number) — \(pr.title)") {
                Button(model.merging.contains(pr.id) ? "Merging…" : "Merge") {
                    Task { await model.merge(pr) }
                }
                .disabled(model.merging.contains(pr.id))
            }
        } else if pr.isDraft {
            Menu("\(pr.repo) #\(pr.number) — \(pr.title)") {
                Button(model.merging.contains(pr.id) ? "Opening for Review…" : "Open for Review") {
                    Task { await model.markReadyForReview(pr) }
                }
                .disabled(model.merging.contains(pr.id))
            }
        } else {
            Button("\(pr.repo) #\(pr.number) — \(pr.title)") {
                if let url = pr.url { NSWorkspace.shared.open(url) }
            }
        }
    }
}
