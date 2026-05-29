import Foundation

/// Talks to the GitHub GraphQL API via the `gh` CLI.
///
/// All blocking subprocess work happens on this actor's executor, never on
/// `@MainActor`. The `PRDashboardModel` stays UI-isolated and `await`s into
/// here for fetches and mutations.
actor GitHubClient {
    private static let prFields = """
    id number title isDraft
    repository { nameWithOwner }
    reviewDecision mergeStateStatus
    autoMergeRequest { enabledAt }
    mergeQueueEntry { enqueuedAt }
    commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 50) { nodes {
      ... on CheckRun { conclusion }
      ... on StatusContext { state }
    } } } } } }
    """

    // MARK: - Queries

    func fetchAllPRs(users: [String]) async -> ([PullRequest]?, String?) {
        var allPRs: [PullRequest] = []
        var seen: Set<String> = []
        var anySuccess = false
        var lastErr: String?

        for user in users {
            var cursor: String? = nil
            while true {
                let afterClause = cursor.map { #", after: "\#($0)""# } ?? ""
                let query = #"{ search(query: "is:pr is:open author:\#(user)", type: ISSUE, first: 20\#(afterClause)) { pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { \#(Self.prFields) } } } }"#

                let (page, err) = await fetchPRPage(query: query)
                if let err { lastErr = err }
                guard let (prs, pageInfo) = page else { break }
                anySuccess = true
                for pr in prs {
                    if seen.insert(pr.id).inserted {
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
        return (anySuccess ? allPRs : nil, lastErr)
    }

    func fetchReviewRequests(users: [String]) async -> ([ReviewRequest]?, String?) {
        var all: [ReviewRequest] = []
        var seen: Set<String> = []
        var anySuccess = false
        var lastErr: String?

        for user in users {
            var cursor: String? = nil
            while true {
                let afterClause = cursor.map { #", after: "\#($0)""# } ?? ""
                let query = #"{ search(query: "is:pr is:open review-requested:\#(user)", type: ISSUE, first: 20\#(afterClause)) { pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { number title repository { nameWithOwner } author { login } } } } }"#

                let (page, err) = await fetchReviewPage(query: query)
                if let err { lastErr = err }
                guard let (reviews, pageInfo) = page else { break }
                anySuccess = true
                for r in reviews {
                    if seen.insert(r.id).inserted {
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
        return (anySuccess ? all : nil, lastErr)
    }

    // MARK: - Mutations

    /// Merge a PR. Pass `mergeMethod = nil` to let the server pick its default
    /// (which is `MERGE`). Returns `(true, nil)` on success.
    func mergePullRequest(nodeId: String, mergeMethod: String? = nil) async -> (Bool, String?) {
        let methodClause = mergeMethod.map { ", mergeMethod: \($0)" } ?? ""
        let mutation = #"mutation { mergePullRequest(input: {pullRequestId: "\#(nodeId)"\#(methodClause)}) { pullRequest { state merged } } }"#
        return await runMutation(mutation)
    }

    func markPullRequestReadyForReview(nodeId: String) async -> (Bool, String?) {
        let mutation = #"mutation { markPullRequestReadyForReview(input: {pullRequestId: "\#(nodeId)"}) { pullRequest { isDraft } } }"#
        return await runMutation(mutation)
    }

    // MARK: - Page parsing

    private func fetchPRPage(query: String) async -> (([PullRequest], [String: Any])?, String?) {
        let body = try! JSONSerialization.data(withJSONObject: ["query": query])
        let (data, err) = await runGH(body: body)
        guard let data else { return (nil, err) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let search = dataObj["search"] as? [String: Any],
              let nodes = search["nodes"] as? [[String: Any]],
              let pageInfo = search["pageInfo"] as? [String: Any]
        else { return (nil, err ?? "malformed response") }

        let prs = nodes.compactMap { node -> PullRequest? in
            guard let nodeId = node["id"] as? String,
                  let number = node["number"] as? Int,
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
                nodeId: nodeId, number: number, title: title, repo: repo, isDraft: isDraft,
                reviewDecision: reviewDecision, mergeStateStatus: mergeStateStatus,
                autoMergeEnabled: autoMerge != nil, inMergeQueue: mergeQueue != nil,
                checkStates: checkStates
            )
        }
        return ((prs, pageInfo), nil)
    }

    private func fetchReviewPage(query: String) async -> (([ReviewRequest], [String: Any])?, String?) {
        let body = try! JSONSerialization.data(withJSONObject: ["query": query])
        let (data, err) = await runGH(body: body)
        guard let data else { return (nil, err) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let search = dataObj["search"] as? [String: Any],
              let nodes = search["nodes"] as? [[String: Any]],
              let pageInfo = search["pageInfo"] as? [String: Any]
        else { return (nil, err ?? "malformed response") }

        let reviews = nodes.compactMap { node -> ReviewRequest? in
            guard let number = node["number"] as? Int,
                  let title = node["title"] as? String,
                  let repo = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String,
                  let author = (node["author"] as? [String: Any])?["login"] as? String
            else { return nil }
            return ReviewRequest(number: number, title: title, repo: repo, author: author)
        }
        return ((reviews, pageInfo), nil)
    }

    private func runMutation(_ mutation: String) async -> (Bool, String?) {
        let body = try! JSONSerialization.data(withJSONObject: ["query": mutation])
        let (data, err) = await runGH(body: body)
        guard let data else { return (false, err) }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
                let msg = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
                return (false, msg.isEmpty ? "unknown GraphQL error" : msg)
            }
            return (true, nil)
        }
        return (false, "malformed response")
    }

    // MARK: - Subprocess

    private func ghPath() -> String {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "gh"
    }

    private func runGH(body: Data) async -> (Data?, String?) {
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(2 * attempt))
            }
            let (data, err) = await runGHOnce(body: body)
            if data != nil { return (data, nil) }
            if let err, err.contains("502"), attempt < 2 { continue }
            return (nil, err ?? "unknown error")
        }
        return (nil, "retries exhausted")
    }

    /// Launch `gh api graphql` and wait for it via `terminationHandler`. We
    /// never call `waitUntilExit()`, so no thread is parked on the child
    /// process.
    private func runGHOnce(body: Data) async -> (Data?, String?) {
        let path = ghPath()
        return await withCheckedContinuation { (continuation: CheckedContinuation<(Data?, String?), Never>) in
            let process = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()
            let inPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["api", "graphql", "--input", "-"]
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = inPipe

            process.terminationHandler = { proc in
                let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: (outData, nil))
                } else {
                    let errStr = (String(data: errData, encoding: .utf8) ?? "unknown error")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: (nil, errStr.isEmpty ? "exit \(proc.terminationStatus)" : errStr))
                }
            }

            do {
                try process.run()
            } catch {
                // run() failed → terminationHandler will not fire, so resume now.
                process.terminationHandler = nil
                continuation.resume(returning: (nil, error.localizedDescription))
                return
            }

            // run() succeeded → terminationHandler will fire when the process
            // exits. Send stdin best-effort; if these fail the process will
            // exit on its own and we still get the termination callback.
            try? inPipe.fileHandleForWriting.write(contentsOf: body)
            try? inPipe.fileHandleForWriting.close()
        }
    }
}
