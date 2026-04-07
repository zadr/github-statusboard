# statusboard

Terminal dashboard for your GitHub PRs.

```
Merging (1)
  - [acme/webapp] Add dark mode toggle (#342)

Approved (1)
  - [acme/webapp] Fix login redirect loop (#338)

Waiting on CI (2)
  - [acme/api] Rate limit middleware (#401)
  - [acme/webapp] Update onboarding copy (#344)

Work Needed (1)
  - [acme/api] Switch to connection pooling (#395)

Open (3)
  - [acme/api] Add pagination to /users endpoint (#399)
  - [acme/docs] Update API authentication guide (#87)
  - [acme/webapp] Lazy load dashboard charts (#340)

Draft (2)
  - [acme/api] gRPC prototype (#402)
  - [acme/webapp] Experiment: server components (#337)

Awaiting Review (2)
  - [acme/api] @alice - Add webhook retry logic (#398)
  - [acme/webapp] @bob - Accessibility audit fixes (#341)
```

## Install

```
swift build -c release
cp .build/release/statusboard /usr/local/bin/
```

## Usage

```
statusboard              # refreshes every 15 minutes
statusboard --once       # print once and exit
statusboard --refresh-interval 1800  # refresh every 30 minutes
```

Requires [`gh`](https://cli.github.com/) authenticated via `gh auth login`.
