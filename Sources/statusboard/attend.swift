import Foundation

@main
struct Attend {
    static func main() async throws {
        let args = CommandLine.arguments
        let once = args.contains("--once")
        var refreshInterval = 900
        if let val = singleValue(args: args, flag: "--refresh-interval").flatMap(Int.init), val > 0 {
            refreshInterval = val
        }
        let filter = RepoFilter(
            includeOrgs: multiValue(args: args, flag: "--include-org"),
            excludeOrgs: multiValue(args: args, flag: "--exclude-org"),
            includeRepos: multiValue(args: args, flag: "--include-repo"),
            excludeRepos: multiValue(args: args, flag: "--exclude-repo")
        )
        let monitorUsers = rawMultiValue(args: args, flag: "--monitor-user")
        let runner = PRDashboard(once: once, refreshInterval: refreshInterval, filter: filter, monitorUsers: monitorUsers)
        await runner.run()
    }

    /// Collect every occurrence of `--flag value` and `--flag=value`. Values may
    /// also be comma-separated (e.g. `--exclude-org=zadr,foo`).
    static func multiValue(args: [String], flag: String) -> [String] {
        rawMultiValue(args: args, flag: flag)
            .flatMap { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
    }

    /// Like `multiValue`, but does not split values on commas. Use for flags
    /// where the value is taken verbatim (e.g. `--monitor-user`).
    static func rawMultiValue(args: [String], flag: String) -> [String] {
        var values: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == flag, i + 1 < args.count {
                values.append(args[i + 1])
                i += 2
            } else if arg.hasPrefix(flag + "=") {
                values.append(String(arg.dropFirst(flag.count + 1)))
                i += 1
            } else {
                i += 1
            }
        }
        return values
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func singleValue(args: [String], flag: String) -> String? {
        multiValue(args: args, flag: flag).last
    }
}

struct RepoFilter: Sendable {
    let includeOrgs: [String]
    let excludeOrgs: [String]
    let includeRepos: [String]
    let excludeRepos: [String]

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
        // NSPredicate LIKE supports `*` (any chars) and `?` (one char).
        // `[c]` is case-insensitive; GitHub orgs/repos are case-insensitive.
        pattern.withCString { pat in string.withCString { str in fnmatch(pat, str, FNM_CASEFOLD) == 0 } }
    }
}

struct PullRequest: Sendable {
    let number: Int
    let title: String
    let repo: String
    let isDraft: Bool
    let reviewDecision: String?
    let mergeStateStatus: String?
    let autoMergeEnabled: Bool
    let inMergeQueue: Bool
    let checkStates: [String]
}

struct ReviewRequest: Sendable {
    let number: Int
    let title: String
    let repo: String
    let author: String
}

enum PRCategory: CaseIterable {
    case merging
    case approved
    case waitingOnCI
    case workNeeded
    case open
    case draft

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
}

actor PRDashboard {
    let once: Bool
    let refreshInterval: Int
    let filter: RepoFilter
    let monitorUsers: [String]
    private var lastPRs: [PullRequest]?
    private var lastReviews: [ReviewRequest]?

    init(once: Bool = false, refreshInterval: Int = 900, filter: RepoFilter = RepoFilter(includeOrgs: [], excludeOrgs: [], includeRepos: [], excludeRepos: []), monitorUsers: [String] = []) {
        self.once = once
        self.refreshInterval = refreshInterval
        self.filter = filter
        self.monitorUsers = monitorUsers
    }

    /// Users to use in `author:` / `review-requested:` qualifiers. When
    /// `--monitor-user` was not provided, fall back to `@me`.
    private var queryUsers: [String] {
        monitorUsers.isEmpty ? ["@me"] : monitorUsers
    }

    func run() async {
        repeat {
            lastError = nil

            if let prs = await fetchAllPRs() { lastPRs = prs }
            if let reviews = await fetchReviewRequests() { lastReviews = reviews }

            let prs = (lastPRs ?? []).filter { filter.allows($0.repo) }
            let reviews = (lastReviews ?? []).filter { filter.allows($0.repo) }
            let grouped = categorize(prs)
            if !once { clearScreen() }
            render(grouped, reviews: reviews, error: lastError)
            if once { return }
            try? await Task.sleep(for: .seconds(refreshInterval))
        } while true
    }

    private func clearScreen() {
        // Move cursor home, clear screen, clear scrollback. Write directly to
        // stdout and flush so the sequence is applied before render() output.
        let seq = "\u{1B}[H\u{1B}[2J\u{1B}[3J"
        FileHandle.standardOutput.write(Data(seq.utf8))
    }

    private static let prFields = """
    number title isDraft
    repository { nameWithOwner }
    reviewDecision mergeStateStatus
    autoMergeRequest { enabledAt }
    mergeQueueEntry { enqueuedAt }
    commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 50) { nodes {
      ... on CheckRun { conclusion }
      ... on StatusContext { state }
    } } } } } }
    """

    private func fetchAllPRs() async -> [PullRequest]? {
        var allPRs: [PullRequest] = []
        var seen: Set<String> = []
        var anySuccess = false

        for user in queryUsers {
            var cursor: String? = nil

            while true {
                let afterClause = cursor.map { #", after: "\#($0)""# } ?? ""
                let query = #"{ search(query: "is:pr is:open author:\#(user)", type: ISSUE, first: 20\#(afterClause)) { pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { \#(Self.prFields) } } } }"#

                guard let (prs, pageInfo) = await fetchPage(query: query) else { break }
                anySuccess = true
                for pr in prs {
                    let key = "\(pr.repo)#\(pr.number)"
                    if seen.insert(key).inserted {
                        allPRs.append(pr)
                    }
                }

                if let hasNext = pageInfo["hasNextPage"] as? Bool, hasNext,
                   let endCursor = pageInfo["endCursor"] as? String {
                    cursor = endCursor
                    try? await Task.sleep(for: .seconds(1))
                } else {
                    break
                }
            }
        }

        return anySuccess ? allPRs : nil
    }

    private func fetchReviewRequests() async -> [ReviewRequest]? {
        var all: [ReviewRequest] = []
        var seen: Set<String> = []
        var anySuccess = false

        for user in queryUsers {
            var cursor: String? = nil

            while true {
                let afterClause = cursor.map { #", after: "\#($0)""# } ?? ""
                let query = #"{ search(query: "is:pr is:open review-requested:\#(user)", type: ISSUE, first: 20\#(afterClause)) { pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { number title repository { nameWithOwner } author { login } } } } }"#

                guard let (reviews, pageInfo) = await fetchReviewPage(query: query) else { break }
                anySuccess = true
                for r in reviews {
                    let key = "\(r.repo)#\(r.number)"
                    if seen.insert(key).inserted {
                        all.append(r)
                    }
                }

                if let hasNext = pageInfo["hasNextPage"] as? Bool, hasNext,
                   let endCursor = pageInfo["endCursor"] as? String {
                    cursor = endCursor
                    try? await Task.sleep(for: .seconds(1))
                } else {
                    break
                }
            }
        }

        return anySuccess ? all : nil
    }

    private func ghPath() -> String {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "gh"
    }

    private var lastError: String?

    private func runGH(body: Data) async -> Data? {
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(2 * attempt))
            }

            let process = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()
            let inPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: ghPath())
            process.arguments = ["api", "graphql", "--input", "-"]
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = inPipe

            do {
                try process.run()
                inPipe.fileHandleForWriting.write(body)
                inPipe.fileHandleForWriting.closeFile()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errStr = (String(data: errData, encoding: .utf8) ?? "unknown error").trimmingCharacters(in: .whitespacesAndNewlines)
                    if errStr.contains("502") && attempt < 2 { continue }
                    lastError = errStr
                    return nil
                }
                return data
            } catch {
                lastError = error.localizedDescription
                return nil
            }
        }
        lastError = "retries exhausted"
        return nil
    }

    private func fetchPage(query: String) async -> ([PullRequest], [String: Any])? {
        let body = try! JSONSerialization.data(withJSONObject: ["query": query])
        guard let data = await runGH(body: body) else { return nil }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let search = dataObj["search"] as? [String: Any],
              let nodes = search["nodes"] as? [[String: Any]],
              let pageInfo = search["pageInfo"] as? [String: Any]
        else { return nil }

        let prs = nodes.compactMap { node -> PullRequest? in
            guard let number = node["number"] as? Int,
                  let title = node["title"] as? String,
                  let isDraft = node["isDraft"] as? Bool,
                  let repo = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String
            else { return nil }

            let reviewDecision = node["reviewDecision"] as? String
            let mergeStateStatus = node["mergeStateStatus"] as? String
            let autoMerge = node["autoMergeRequest"] as? [String: Any]
            let mergeQueue = node["mergeQueueEntry"] as? [String: Any]

            var checkStates: [String] = []
            if let commits = node["commits"] as? [String: Any],
               let commitNodes = commits["nodes"] as? [[String: Any]],
               let lastCommit = commitNodes.last,
               let commit = lastCommit["commit"] as? [String: Any],
               let rollup = commit["statusCheckRollup"] as? [String: Any],
               let contexts = rollup["contexts"] as? [String: Any],
               let ctxNodes = contexts["nodes"] as? [[String: Any]] {
                for ctx in ctxNodes {
                    if let conclusion = ctx["conclusion"] as? String {
                        checkStates.append(conclusion)
                    } else if let state = ctx["state"] as? String {
                        checkStates.append(state)
                    }
                }
            }

            return PullRequest(
                number: number,
                title: title,
                repo: repo,
                isDraft: isDraft,
                reviewDecision: reviewDecision,
                mergeStateStatus: mergeStateStatus,
                autoMergeEnabled: autoMerge != nil,
                inMergeQueue: mergeQueue != nil,
                checkStates: checkStates
            )
        }
        return (prs, pageInfo)
    }

    private func fetchReviewPage(query: String) async -> ([ReviewRequest], [String: Any])? {
        let body = try! JSONSerialization.data(withJSONObject: ["query": query])
        guard let data = await runGH(body: body) else { return nil }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let search = dataObj["search"] as? [String: Any],
              let nodes = search["nodes"] as? [[String: Any]],
              let pageInfo = search["pageInfo"] as? [String: Any]
        else { return nil }

        let reviews = nodes.compactMap { node -> ReviewRequest? in
            guard let number = node["number"] as? Int,
                  let title = node["title"] as? String,
                  let repo = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String,
                  let author = (node["author"] as? [String: Any])?["login"] as? String
            else { return nil }
            return ReviewRequest(number: number, title: title, repo: repo, author: author)
        }
        return (reviews, pageInfo)
    }

    private func categorize(_ prs: [PullRequest]) -> [PRCategory: [PullRequest]] {
        var result: [PRCategory: [PullRequest]] = [:]
        for cat in PRCategory.allCases { result[cat] = [] }

        for pr in prs {
            let category: PRCategory
            if pr.isDraft {
                category = .draft
            } else if pr.reviewDecision == "CHANGES_REQUESTED" || hasFailingChecks(pr) {
                category = .workNeeded
            } else if pr.reviewDecision != "APPROVED" {
                category = .open
            } else if hasPendingChecks(pr) {
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

    private func hasFailingChecks(_ pr: PullRequest) -> Bool {
        pr.checkStates.contains { $0 == "FAILURE" || $0 == "ERROR" }
    }

    private func hasPendingChecks(_ pr: PullRequest) -> Bool {
        pr.checkStates.contains { $0 == "PENDING" }
    }

    private func render(_ grouped: [PRCategory: [PullRequest]], reviews: [ReviewRequest], error: String?) {
        let reset = "\u{1B}[0m"
        let bold = "\u{1B}[1m"
        let red = "\u{1B}[31m"

        for category in PRCategory.allCases {
            let prs = (grouped[category] ?? []).sorted { ($0.repo, $0.number) < ($1.repo, $1.number) }
            print("\(bold)\(category.label) (\(prs.count))\(reset)")
            if prs.isEmpty {
                print()
            } else {
                for pr in prs {
                    print("  - [\(pr.repo)] \(pr.title) (#\(pr.number))")
                }
                print()
            }
        }

        let sortedReviews = reviews.sorted { ($0.repo, $0.number) < ($1.repo, $1.number) }
        print("\(bold)Awaiting Review (\(sortedReviews.count))\(reset)")
        if !sortedReviews.isEmpty {
            for r in sortedReviews {
                print("  - [\(r.repo)] @\(r.author) - \(r.title) (#\(r.number))")
            }
        }
        print()

        if let error {
            print("\(red)\(error)\(reset)")
        }
    }
}
