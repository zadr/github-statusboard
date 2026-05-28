import Foundation

@main
struct Attend {
    static func main() async throws {
        let args = CommandLine.arguments
        let once = args.contains("--once")
        var refreshInterval = 900
        if let idx = args.firstIndex(of: "--refresh-interval"), idx + 1 < args.count,
           let val = Int(args[idx + 1]), val > 0 {
            refreshInterval = val
        }
        let runner = PRDashboard(once: once, refreshInterval: refreshInterval)
        await runner.run()
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
    private var lastPRs: [PullRequest]?
    private var lastReviews: [ReviewRequest]?

    init(once: Bool = false, refreshInterval: Int = 900) {
        self.once = once
        self.refreshInterval = refreshInterval
    }

    func run() async {
        repeat {
            lastError = nil

            if let prs = await fetchAllPRs() { lastPRs = prs }
            if let reviews = await fetchReviewRequests() { lastReviews = reviews }

            let grouped = categorize(lastPRs ?? [])
            if !once { clearScreen() }
            render(grouped, reviews: lastReviews ?? [], error: lastError)
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
        var cursor: String? = nil

        for _ in 0..<5 {
            let afterClause = cursor.map { #", after: "\#($0)""# } ?? ""
            let query = #"{ search(query: "is:pr is:open author:@me", type: ISSUE, first: 20\#(afterClause)) { pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { \#(Self.prFields) } } } }"#

            guard let (prs, pageInfo) = await fetchPage(query: query) else {
                return allPRs.isEmpty ? nil : allPRs
            }
            allPRs.append(contentsOf: prs)

            if let hasNext = pageInfo["hasNextPage"] as? Bool, hasNext,
               let endCursor = pageInfo["endCursor"] as? String {
                cursor = endCursor
                try? await Task.sleep(for: .seconds(1))
            } else {
                break
            }
        }
        return allPRs
    }

    private func fetchReviewRequests() async -> [ReviewRequest]? {
        var all: [ReviewRequest] = []
        var cursor: String? = nil

        for _ in 0..<5 {
            let afterClause = cursor.map { #", after: "\#($0)""# } ?? ""
            let query = #"{ search(query: "is:pr is:open review-requested:@me", type: ISSUE, first: 20\#(afterClause)) { pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { number title repository { nameWithOwner } author { login } } } } }"#

            guard let (reviews, pageInfo) = await fetchReviewPage(query: query) else {
                return all.isEmpty ? nil : all
            }
            all.append(contentsOf: reviews)

            if let hasNext = pageInfo["hasNextPage"] as? Bool, hasNext,
               let endCursor = pageInfo["endCursor"] as? String {
                cursor = endCursor
                try? await Task.sleep(for: .seconds(1))
            } else {
                break
            }
        }
        return all
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
