import Foundation
import Observation

/// Atomic snapshot of everything the menu's PR / review list reads. We update
/// `state` once at the end of a refresh — `@Observable` then fires a single
/// invalidation, so SwiftUI rebuilds the NSMenu once per refresh instead of
/// 4–6 times (one per individual property write).
struct DashboardState: Sendable, Equatable {
    var prs: [PullRequest] = []
    var reviews: [ReviewRequest] = []
    var lastUpdated: Date?
    var lastError: String?
}

/// UI-facing dashboard state. Every property and method is `@MainActor`.
///
/// All work that touches the network or `gh` lives on `GitHubClient`, which is
/// its own `actor`. From the main actor we just `await` into that actor —
/// `await` releases the main thread for the duration of the cross-actor work.
@MainActor
@Observable
final class PRDashboardModel {
    /// All "what to show" data lives here. One observation event per refresh.
    var state: DashboardState = DashboardState()

    /// Whether a refresh is currently running. Read by UI affordances *outside*
    /// the long PR list (the menu bar label, the "Refresh Now" button), so
    /// flipping it during a refresh doesn't invalidate the list body.
    var isRefreshing: Bool = false

    /// PR ids with an in-flight mutation (merge / mark ready).
    var merging: Set<String> = []

    var filter: RepoFilter {
        didSet { saveFilter() }
    }
    var monitorUsers: [String] {
        didSet { saveMonitorUsers() }
    }
    var refreshInterval: TimeInterval {
        didSet { saveRefreshInterval(); restartTimer() }
    }

    private let client = GitHubClient()
    private let defaults = UserDefaults.standard
    private var refreshTask: Task<Void, Never>?

    init() {
        let inc = defaults.stringArray(forKey: "includeOrgs") ?? []
        let exc = defaults.stringArray(forKey: "excludeOrgs") ?? []
        let incR = defaults.stringArray(forKey: "includeRepos") ?? []
        let excR = defaults.stringArray(forKey: "excludeRepos") ?? []
        self.filter = RepoFilter(includeOrgs: inc, excludeOrgs: exc, includeRepos: incR, excludeRepos: excR)
        self.monitorUsers = defaults.stringArray(forKey: "monitorUsers") ?? []
        let stored = defaults.double(forKey: "refreshInterval")
        self.refreshInterval = stored > 0 ? stored : 900
    }

    // MARK: - Derived state

    var filteredPRs: [PullRequest] {
        state.prs.filter { filter.allows($0.repo) }
    }

    var filteredReviews: [ReviewRequest] {
        state.reviews.filter { filter.allows($0.repo) }
    }

    var grouped: [(PRCategory, [PullRequest])] {
        let bucket = Self.categorize(filteredPRs)
        return PRCategory.allCases.map { ($0, (bucket[$0] ?? []).sorted { ($0.repo, $0.number) < ($1.repo, $1.number) }) }
    }

    var totalOpenItems: Int {
        filteredPRs.count + filteredReviews.count
    }

    var attentionCount: Int {
        let work = filteredPRs.filter { pr in
            if pr.isDraft { return false }
            if pr.reviewDecision == "CHANGES_REQUESTED" { return true }
            if pr.checkStates.contains(where: { $0 == "FAILURE" || $0 == "ERROR" }) { return true }
            return false
        }
        return work.count + filteredReviews.count
    }

    // MARK: - Lifecycle

    func start() {
        restartTimer()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func restartTimer() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = self.refreshInterval
                try? await Task.sleep(for: .seconds(max(30, interval)))
            }
        }
    }

    // MARK: - Actions

    /// Fetch the latest PRs + review requests. Heavy work happens inside the
    /// `GitHubClient` actor; this method just `await`s the results.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let users = monitorUsers.isEmpty ? ["@me"] : monitorUsers

        async let prResult = client.fetchAllPRs(users: users)
        async let reviewResult = client.fetchReviewRequests(users: users)
        let (newPRs, prErr) = await prResult
        let (newReviews, reviewErr) = await reviewResult

        // Build a fresh snapshot off the existing one, then assign once. This
        // collapses 3-4 individual property writes into a single observation
        // event, so the NSMenu rebuilds exactly once.
        var next = state
        if let newPRs { next.prs = newPRs }
        if let newReviews { next.reviews = newReviews }
        next.lastError = prErr ?? reviewErr
        next.lastUpdated = Date()
        state = next
    }

    /// Merge an approved PR using GitHub's default merge method. On a method
    /// disabled error we fall back to SQUASH, then REBASE.
    func merge(_ pr: PullRequest) async {
        guard !merging.contains(pr.id) else { return }
        merging.insert(pr.id)
        defer { merging.remove(pr.id) }

        let attempts: [String?] = [nil, "SQUASH", "REBASE"]
        var lastErr: String?
        for method in attempts {
            let (ok, err) = await client.mergePullRequest(nodeId: pr.nodeId, mergeMethod: method)
            if ok {
                state.lastError = nil
                await refresh()
                return
            }
            lastErr = err
            if let err, !Self.isMergeMethodError(err) { break }
        }
        state.lastError = lastErr ?? "merge failed"
    }

    /// Promote a draft PR out of draft state ("Ready for review").
    func markReadyForReview(_ pr: PullRequest) async {
        guard !merging.contains(pr.id) else { return }
        merging.insert(pr.id)
        defer { merging.remove(pr.id) }

        let (ok, err) = await client.markPullRequestReadyForReview(nodeId: pr.nodeId)
        if ok {
            state.lastError = nil
            await refresh()
        } else {
            state.lastError = err ?? "could not open for review"
        }
    }

    // MARK: - Categorization

    static func categorize(_ prs: [PullRequest]) -> [PRCategory: [PullRequest]] {
        var result: [PRCategory: [PullRequest]] = [:]
        for cat in PRCategory.allCases { result[cat] = [] }
        for pr in prs {
            let category: PRCategory
            if pr.isDraft {
                category = .draft
            } else if pr.reviewDecision == "CHANGES_REQUESTED" || pr.checkStates.contains(where: { $0 == "FAILURE" || $0 == "ERROR" }) {
                category = .workNeeded
            } else if pr.reviewDecision != "APPROVED" {
                category = .open
            } else if pr.checkStates.contains(where: { $0 == "PENDING" }) {
                category = .waitingOnCI
            } else if pr.inMergeQueue || pr.autoMergeEnabled {
                category = .merging
            } else {
                category = .approved
            }
            result[category, default: []].append(pr)
        }
        return result
    }

    /// Heuristic: GitHub's error message when a merge method is disabled looks
    /// like "Merge commits are not allowed on this repository." or similar.
    private static func isMergeMethodError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("not allowed") || lower.contains("disabled") || lower.contains("merge_method")
    }

    // MARK: - Persistence

    private func saveFilter() {
        defaults.set(filter.includeOrgs, forKey: "includeOrgs")
        defaults.set(filter.excludeOrgs, forKey: "excludeOrgs")
        defaults.set(filter.includeRepos, forKey: "includeRepos")
        defaults.set(filter.excludeRepos, forKey: "excludeRepos")
    }

    private func saveMonitorUsers() {
        defaults.set(monitorUsers, forKey: "monitorUsers")
    }

    private func saveRefreshInterval() {
        defaults.set(refreshInterval, forKey: "refreshInterval")
    }
}
