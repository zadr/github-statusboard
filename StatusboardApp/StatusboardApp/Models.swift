import Foundation

struct RepoFilter: Sendable, Equatable {
    var includeOrgs: [String] = []
    var excludeOrgs: [String] = []
    var includeRepos: [String] = []
    var excludeRepos: [String] = []

    var isEmpty: Bool {
        includeOrgs.isEmpty && excludeOrgs.isEmpty && includeRepos.isEmpty && excludeRepos.isEmpty
    }

    /// `nameWithOwner` is "org/repo". Returns true if it passes every filter.
    func allows(_ nameWithOwner: String) -> Bool {
        if isEmpty { return true }
        let parts = nameWithOwner.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return true }
        let org = parts[0]
        let repo = parts[1]

        if !includeOrgs.isEmpty, !includeOrgs.contains(where: { Self.glob($0, org) }) { return false }
        if excludeOrgs.contains(where: { Self.glob($0, org) }) { return false }
        if !includeRepos.isEmpty, !includeRepos.contains(where: { Self.glob($0, repo) }) { return false }
        if excludeRepos.contains(where: { Self.glob($0, repo) }) { return false }
        return true
    }

    private static func glob(_ pattern: String, _ string: String) -> Bool {
        pattern.withCString { pat in string.withCString { str in fnmatch(pat, str, FNM_CASEFOLD) == 0 } }
    }
}

struct PullRequest: Sendable, Identifiable, Hashable {
    /// GraphQL node ID, needed for the `mergePullRequest` mutation.
    let nodeId: String
    let number: Int
    let title: String
    let repo: String
    let isDraft: Bool
    let reviewDecision: String?
    let mergeStateStatus: String?
    let autoMergeEnabled: Bool
    let inMergeQueue: Bool
    let checkStates: [String]

    var id: String { "\(repo)#\(number)" }

    var url: URL? {
        URL(string: "https://github.com/\(repo)/pull/\(number)")
    }

    /// "Approved with green CI" — used to decide whether to surface the
    /// Merge action in the menu.
    var isApprovedAndMergeable: Bool {
        !isDraft
            && reviewDecision == "APPROVED"
            && !checkStates.contains(where: { $0 == "FAILURE" || $0 == "ERROR" || $0 == "PENDING" })
    }
}

struct ReviewRequest: Sendable, Identifiable, Hashable {
    let number: Int
    let title: String
    let repo: String
    let author: String

    var id: String { "\(repo)#\(number)" }

    var url: URL? {
        URL(string: "https://github.com/\(repo)/pull/\(number)")
    }
}

enum PRCategory: String, CaseIterable, Identifiable {
    case merging
    case approved
    case waitingOnCI
    case workNeeded
    case open
    case draft

    var id: String { rawValue }

    var label: String {
        switch self {
        case .merging: "Merging"
        case .approved: "Approved"
        case .waitingOnCI: "Waiting on CI"
        case .workNeeded: "Work Needed"
        case .open: "Open"
        case .draft: "Draft"
        }
    }

    var symbol: String {
        switch self {
        case .merging: "arrow.triangle.merge"
        case .approved: "checkmark.seal"
        case .waitingOnCI: "clock"
        case .workNeeded: "exclamationmark.triangle"
        case .open: "circle.dotted"
        case .draft: "pencil"
        }
    }
}
