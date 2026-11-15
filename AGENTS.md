# LumaVault Agent & Multi-Worktree Development Guide

Always read [`docs/BLUEPRINT.md`](docs/BLUEPRINT.md) for the full architecture and system design.

## 1. Multi-Worktree Ownership & Linear Scoping Rules

Each AI agent conversation works in an isolated **git worktree** mapped to a specific **Linear Issue** in the **Lumavault (`LUM`)** team.
- **Artifact review before creating Linear issues:** When scoping a project or milestone, **never create issues in Linear directly**. First write the proposed Linear issues (titles, descriptions, owned paths, dependencies, and acceptance criteria) to a Markdown artifact for user comments and review, and wait for explicit approval before creating them in Linear.
- **Stay strictly inside your issue's owned paths:** Do not edit files outside the directory/package assigned to your Linear issue unless the issue explicitly covers cross-package integration.
- **Contracts are the boundary:** `proto/lumavault/v1/`, `pkg/metadata/store.go` (`MetadataStore`), and `pkg/chunkstore/store.go` (`ChunkStore`) are shared contracts. Do not break their signatures without updating all callers and regenerating stubs (`make proto`). Generated Protobuf stubs (`gen/go/`, `sdk/web/src/gen/`, `sdk/swift/Sources/LumaVaultSDK/Gen/`) are gitignored and generated on demand via `make proto`.

| Linear Project | Owned Paths |
| :--- | :--- |
| **`P-LUM-1` Core Backend, Contracts & Basic Data Layer** | `proto/lumavault/v1/storage.proto`, `buf.*`, `Makefile`, `.gitignore`, `go.*`, `Package.swift`, `sdk/web/package.json`, `sdk/web/tsconfig.json`, `pkg/metadata/`, `pkg/chunkstore/`, `pkg/gateway/`, `cmd/lumavault/` |
| **`P-LUM-2` Client SDKs (Web/TypeScript & Swift)** | `sdk/web/`, `sdk/swift/`, `Package.swift` |
| **`P-LUM-3` LumaVault Photos** | `apps/photos/` |
| **`P-LUM-4` LumaVault Cinema** | `apps/cinema/` |
| **`P-LUM-5` LumaVault Arcade** | `apps/arcade/` |
| **`P-LUM-6` Distributed Systems Upgrades** | `proto/lumavault/v1/paxos.proto`, `proto/lumavault/v1/chunk.proto`, `pkg/consensus/`, `pkg/chunkserver/` |

## 2. Core Architectural Invariants

1. **Pluggable Backend Stores:** The Gateway (`pkg/gateway/`) talks **only** to the `MetadataStore` (`pkg/metadata/`) and `ChunkStore` (`pkg/chunkstore/`) Go interfaces—never directly to local disk files or Paxos/Chunkserver internals.
2. **Content-Addressed Chunks (`4MB–64MB` over Raw HTTP):** Raw media bytes never enter `MetadataStore`, the Paxos log, or Protobuf messages. All blobs are sliced into `SHA-256` verified chunks (`4MB–64MB`, with `chunk_size_bytes` recorded on `ObjectMetadata` for $O(1)$ byte-range seeking) and streamed directly via `PUT /v1/chunks/{sha256}` and `GET /v1/chunks/{sha256}` in `ChunkStore`.
3. **Dual Client Support (Web + Swift via Connect-RPC + Raw HTTP Data Plane):** A single `connectrpc/go` Gateway handler serves Connect, binary gRPC, and gRPC-Web for the Control Plane (`StorageService`: `HasChunks`, `CommitObject`, metadata queries), alongside raw HTTP Data Plane endpoints (`PUT /v1/chunks/{sha256}`, `GET /v1/chunks/{sha256}`, and `HTTP 206 Partial Content` `GET /v1/stream/{object_id}`) so both `sdk/web` (`@connectrpc/connect-web`) and `sdk/swift` (`connectrpc/swift`) work out of the box without separate `grpc-go` server boilerplate.
4. **No Media in Git:** Never commit copyrighted media, ROMs, BIOS files, or `.env` secrets to the repository.

## 3. Standard Commands

- `make proto` — Run `buf lint` and `buf generate` (Go, Swift, and TypeScript/Connect-ES stubs).
- `make lint` — Run `buf lint`, `go vet ./...`, and SDK static checks.
- `make test` — Run Go unit/integration tests (`go test -race ./...`) and SDK tests.
- `make build` — Compile `cmd/lumavault`.

## 4. Branch, Pull Request & Linear Linking Workflow

Never commit or push directly to `main`. Every change follows this lifecycle:
1. **Branch Off `origin/main`:** Fetch `origin` (`git fetch origin`) and create a branch named with the Linear issue's `gitBranchName` (e.g., `zvishrut/lum-XX-...` or `<type>/<slug>` for non-issue chores, inside an isolated `git worktree` when working in parallel). Keep `git config core.hooksPath .githooks` enabled so direct commits and pushes to `main` are blocked locally.
2. **Verify Locally:** Run `make lint` and `make test` before pushing.
3. **Open a PR & Link Linear:** Push the branch (`git push -u origin HEAD`), open a GitHub Pull Request via `gh pr create` referencing `LUM-XX` in the title/body, and attach the PR URL to the Linear issue via `save_issue(id, links: [{url, title}])` while keeping the issue `In Progress` until the PR is merged.
4. **Run `ponytail-review` PR Review Agent:** Launch a fresh `self` subagent (`invoke_subagent`), passing `<worktree>`, `<base>`, and `<pr>`, that loads the `ponytail-review` skill, inspects `git -C <worktree> diff origin/<base>...HEAD` plus touched callers, tests, and contracts under `<worktree>`, writes the review JSON to `/tmp/pr-<pr>-review.json` (full 40-char `commit_id` from `git -C <worktree> rev-parse HEAD`, `event: "COMMENT"` since GitHub blocks self-`APPROVE`/`REQUEST_CHANGES`, `[AGENT]`-prefixed summary `body` with `Verdict:`, and `[AGENT]`-prefixed inline `comments` with `{path, line, side: "RIGHT", body}` strictly on lines inside the PR diff hunks—put findings on unchanged callers in `body`), and posts it via `gh api repos/AgrawalVi/lumavault/pulls/<pr>/reviews --method POST --input /tmp/pr-<pr>-review.json`. **Never push directly to `main` or self-merge PRs**—leave every PR and its `[AGENT]` review comments open for user review and passing CI checks; when asked to address PR comments, push follow-up commits and reply in-thread with `[AGENT]` (`gh api repos/AgrawalVi/lumavault/pulls/<pr>/comments/<comment_id>/replies -f body="[AGENT] ..."`).
